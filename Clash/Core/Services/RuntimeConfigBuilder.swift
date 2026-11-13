import Foundation
import Security
import Yams

/// 生成 `runtime/runtime.yaml`：用户配置**解析 → 覆盖注入键 → 序列化**。
///
/// 规则见 `core-process` §4 与 ADR-0005：
/// - 只用 Yams 解析 / 序列化，禁止字符串拼接（同名键追加会让 `mihomo -t` 直接失败）
/// - 用户配置永不改写：所有注入只写进 `runtime/`，`profiles/` 保持原样
/// - `proxies` / `proxy-groups` / `rules` 一律不碰；`tun` 允许存在但强制关闭（v0.2 前无 helper）
/// - secret 只落运行配置（0600），不进日志
enum RuntimeConfigBuilder {

    static let defaultMixedPort = 7890

    /// 本次启动要注入的值。端口与 secret 由 `KernelService` 决定并复用给 API 客户端。
    struct Injected: Sendable {
        var mixedPort: Int = RuntimeConfigBuilder.defaultMixedPort
        var controllerPort: Int
        var dnsPort: Int
        var secret: String
        var logLevel: String = "info"
    }

    // MARK: - 入口

    /// 生成运行配置并返回其路径。
    ///
    /// - `profileURL == nil`：没有用户配置，生成最小可用配置（v0.1 行为）
    /// - 否则：读取、解析、覆盖注入键、写出；解析失败 / 顶层不是映射 → `configInvalid`
    @discardableResult
    static func build(from profileURL: URL?, injected: Injected) throws -> URL {
        let root = try makeRoot(profileURL: profileURL, injected: injected)
        let yaml = try dump(root)
        try writeAtomically(yaml, to: AppPaths.runtimeConfigURL)
        return AppPaths.runtimeConfigURL
    }

    /// 32 字节随机数转 hex；`SecRandomCopyBytes` 不可用时退回两个 UUID
    static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    // MARK: - 解析与注入

    private static func makeRoot(profileURL: URL?, injected: Injected) throws -> [String: Any] {
        guard let profileURL else {
            return minimalRoot(injected: injected)
        }

        let text: String
        do {
            text = try String(contentsOf: profileURL, encoding: .utf8)
        } catch {
            throw KernelError.configInvalid(detail: "读取配置失败：\(error.localizedDescription)")
        }

        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: text)
        } catch {
            // 含重复键（Yams 在解析阶段就会报 duplicatedKeysInMapping）
            throw KernelError.configInvalid(detail: "YAML 解析失败：\(describeParseError(error))")
        }

        guard let raw = loaded as? [AnyHashable: Any] else {
            throw KernelError.configInvalid(detail: "配置顶层必须是映射（键值对）")
        }
        guard let mapping = normalize(raw) as? [String: Any] else {
            throw KernelError.configInvalid(detail: "配置顶层必须是映射（键值对）")
        }

        var root = mapping
        applyInjection(to: &root, injected: injected)
        return root
    }

    /// 无 profile：最小可用配置（与 v0.1 一致）
    private static func minimalRoot(injected: Injected) -> [String: Any] {
        var root: [String: Any] = [:]
        applyInjection(to: &root, injected: injected)
        root["dns"] = [
            "enable": true,
            "listen": "127.0.0.1:\(injected.dnsPort)",
            "ipv6": false
        ]
        return root
    }

    /// 覆盖注入键（`core-process` §4）。其余键原样保留。
    private static func applyInjection(to root: inout [String: Any], injected: Injected) {
        root["mixed-port"] = injected.mixedPort
        // v0.2 只用 mixed-port：旧式 http / socks 端口一并删除，避免出现未受管入口
        root.removeValue(forKey: "port")
        root.removeValue(forKey: "socks-port")

        root["allow-lan"] = false
        root["bind-address"] = "127.0.0.1"

        if let mode = root["mode"] as? String, !mode.isEmpty {
            root["mode"] = mode
        } else {
            root["mode"] = "rule"
        }

        root["log-level"] = injected.logLevel
        root["external-controller"] = "127.0.0.1:\(injected.controllerPort)"
        root["secret"] = injected.secret

        var dns = (root["dns"] as? [String: Any]) ?? [:]
        dns["listen"] = "127.0.0.1:\(injected.dnsPort)"
        root["dns"] = dns

        // v0.1 / v0.2 前期没有 helper：订阅里带 tun 也只保留结构，强制关闭
        if var tun = root["tun"] as? [String: Any] {
            tun["enable"] = false
            root["tun"] = tun
        }
    }

    /// Yams 的映射是 `[AnyHashable: Any]`；统一成 `[String: Any]`，数组逐项处理
    private static func normalize(_ value: Any) -> Any {
        if let mapping = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            result.reserveCapacity(mapping.count)
            for (key, nested) in mapping {
                result[String(describing: key)] = normalize(nested)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(normalize)
        }
        return value
    }

    // MARK: - 序列化与落盘

    private static func dump(_ root: [String: Any]) throws -> String {
        do {
            return try Yams.dump(object: root, allowUnicode: true)
        } catch {
            throw KernelError.configInvalid(detail: "配置序列化失败：\(describeParseError(error))")
        }
    }

    /// 只报类别，不回显 YAML 片段：配置文件里可能有节点密码 / 订阅 token
    private static func describeParseError(_ error: Error) -> String {
        guard let yamlError = error as? YamlError else { return "YAML 语法错误" }
        switch yamlError {
        case .duplicatedKeysInMapping(_, _):
            return "存在重复键（同一层级同名键出现多次）"
        default:
            return "YAML 语法错误"
        }
    }

    /// 临时文件写好并改成 0600 后再 rename，避免出现「可读但还没收紧权限」的窗口
    private static func writeAtomically(_ yaml: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appending(path: ".runtime-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: tempURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}
