import Foundation
import Security
import Yams

/// 生成 `runtime/runtime.yaml`：用户配置**解析 → 覆盖注入键 → 序列化**。
///
/// 规则见 `core-process` §4 与 ADR-0005：
/// - 只用 Yams 解析 / 序列化，禁止字符串拼接（同名键追加会让 `mihomo -t` 直接失败）
/// - 用户配置永不改写：所有注入只写进 `runtime/`，`profiles/` 保持原样
/// - `proxies` / `proxy-groups` / `rules` 一律不碰
/// - TUN：`Injected.tunEnabled` 为真时**整体替换** `tun` 段并强制 fake-ip DNS；
///   为假时只留 `tun.enable=false`，完全不复用订阅里的 `tun` 配置
/// - secret 只落运行配置（0600），不进日志
enum RuntimeConfigBuilder {

    static let defaultMixedPort = 7890

    /// TUN 的转发栈：`gvisor`（用户态，兼容性最好）/ `system`（系统栈，需要内核支持）
    enum TunStack: String, Sendable {
        case gvisor
        case system
    }

    /// 本次启动要注入的值。端口与 secret 由 `KernelService` / `TunService` 决定并复用给 API 客户端。
    struct Injected: Sendable {
        var mixedPort: Int = RuntimeConfigBuilder.defaultMixedPort
        var allowLAN: Bool = false
        var controllerPort: Int
        var dnsPort: Int
        var secret: String
        var logLevel: String = "info"
        /// 是否以 TUN 模式运行（`true` 时 helper 以 root 启动内核）
        var tunEnabled: Bool = false
        var tunStack: TunStack = .gvisor
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

    /// **只生成正文，不落盘**：TUN 模式下正文经 XPC 交给 helper，由 helper 写到 root 目录。
    ///
    /// 与 `build(from:injected:)` 共用同一套解析 / 注入逻辑，避免「App 校验的配置」
    /// 和「helper 实际运行的配置」出现两份实现。
    static func yaml(from profileURL: URL?, injected: Injected) throws -> String {
        try dump(makeRoot(profileURL: profileURL, injected: injected))
    }


    /// 用**尚未入库**的配置正文生成一份运行配置，写到指定路径。
    ///
    /// 订阅导入 / 更新时先用它生成临时 runtime，再交给 `mihomo -t` 校验（`ProfileValidator`）；
    /// 绝不覆盖正在使用的 `runtime/runtime.yaml`。
    @discardableResult
    static func build(yamlText: String, injected: Injected, to destination: URL) throws -> URL {
        let root = try makeRoot(yamlText: yamlText, injected: injected)
        let yaml = try dump(root)
        try writeAtomically(yaml, to: destination)
        return destination
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

        return try makeRoot(yamlText: text, injected: injected)
    }

    private static func makeRoot(yamlText text: String, injected: Injected) throws -> [String: Any] {
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
        // 只给默认值，其余键（enable / listen / fake-ip …）交给 `applyInjection` 统一注入，
        // 否则 TUN 模式下的 fake-ip 段会被这里覆盖掉
        var root: [String: Any] = ["dns": ["ipv6": false]]
        applyInjection(to: &root, injected: injected)
        return root
    }

    /// 覆盖注入键（`core-process` §4）。其余键原样保留。
    private static func applyInjection(to root: inout [String: Any], injected: Injected) {
        root["mixed-port"] = injected.mixedPort
        // v0.2 只用 mixed-port：旧式 http / socks 端口一并删除，避免出现未受管入口
        root.removeValue(forKey: "port")
        root.removeValue(forKey: "socks-port")

        root["allow-lan"] = injected.allowLAN
        // `bind-address: 127.0.0.1` 与 `allow-lan: false` 配套；开了局域网访问就必须放开监听地址，
        // 否则局域网客户端连不上（控制端口仍固定 127.0.0.1，不受影响）
        if injected.allowLAN {
            root.removeValue(forKey: "bind-address")
        } else {
            root["bind-address"] = "127.0.0.1"
        }

        if let mode = root["mode"] as? String, !mode.isEmpty {
            root["mode"] = mode
        } else {
            root["mode"] = "rule"
        }

        root["log-level"] = injected.logLevel
        root["external-controller"] = "127.0.0.1:\(injected.controllerPort)"
        root["secret"] = injected.secret

        root["dns"] = dnsSection(injected: injected, existing: root["dns"] as? [String: Any])
        root["tun"] = tunSection(injected: injected)
    }

    /// DNS 段：启用并只监听回环（订阅里常见的 `0.0.0.0` 必须被覆盖，否则等于开放递归解析）。
    ///
    /// TUN 模式额外强制 `fake-ip`：`dns-hijack: any:53` 把全部 DNS 查询劫持进来，
    /// 没有 fake-ip 就只能逐个真解析，连接建立的延迟会明显变差。
    private static func dnsSection(injected: Injected, existing: [String: Any]?) -> [String: Any] {
        var dns = existing ?? [:]
        dns["enable"] = true
        dns["listen"] = "127.0.0.1:\(injected.dnsPort)"
        if injected.tunEnabled {
            dns["enhanced-mode"] = "fake-ip"
            dns["fake-ip-range"] = "198.18.0.1/16"
        }
        return dns
    }

    /// `tun` 段：**整段替换**，不 merge。
    ///
    /// - 开：五个键全部由 App 决定（订阅里的 `device` / `stack` / `mtu` 一律丢弃），
    ///   避免机场配置里的 `stack: system` 或旧的 `device: utun1024` 影响本机
    /// - 关：只写 `enable: false`，同样整段丢弃订阅内容（「不复用订阅里的 tun 配置」）
    private static func tunSection(injected: Injected) -> [String: Any] {
        guard injected.tunEnabled else { return ["enable": false] }

        return [
            "enable": true,
            "stack": injected.tunStack.rawValue,
            "auto-route": true,
            "auto-detect-interface": true,
            "dns-hijack": ["any:53"]
        ]
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
