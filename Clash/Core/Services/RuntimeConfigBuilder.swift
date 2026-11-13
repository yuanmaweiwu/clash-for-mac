import Foundation
import Security

/// 一次启动使用的 runtime 配置（无 profile 时的最小可用集合）。
///
/// 内容按 `core-process` §4 生成，**不拼接用户配置**：v0.1 还没有 profile，
/// 先跑通「二进制 → 配置 → 启动 → /version」；接入订阅后再换成 YAML 解析注入。
struct RuntimeConfig: Sendable {

    static let defaultMixedPort = 7890

    var mixedPort: Int = RuntimeConfig.defaultMixedPort
    var controllerPort: Int
    var dnsPort: Int
    var secret: String

    /// 最小可用配置；`external-controller` 与 `dns.listen` 固定回环地址。
    var yaml: String {
        """
        mixed-port: \(mixedPort)
        allow-lan: false
        bind-address: 127.0.0.1
        mode: rule
        log-level: info
        external-controller: 127.0.0.1:\(controllerPort)
        secret: "\(secret)"
        dns:
          enable: true
          listen: 127.0.0.1:\(dnsPort)
          ipv6: false
        """
    }
}

enum RuntimeConfigBuilder {

    static func make(controllerPort: Int, dnsPort: Int, mixedPort: Int = RuntimeConfig.defaultMixedPort) -> RuntimeConfig {
        RuntimeConfig(mixedPort: mixedPort, controllerPort: controllerPort, dnsPort: dnsPort, secret: makeSecret())
    }

    /// 每次启动重建 runtime 配置（临时文件 + rename 原子替换）
    static func write(_ config: RuntimeConfig, to url: URL) throws {
        try Data(config.yaml.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 32 字节随机数转 hex；`SecRandomCopyBytes` 不可用时退回两个 UUID（同样 32 字节）
    static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}
