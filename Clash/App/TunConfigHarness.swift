#if DEBUG
import Foundation
import Yams

/// TUN 运行配置自检（仅 DEBUG）：`CLASH_TUN_CONFIG_HARNESS=1` 时在 UI 起来前跑并退出。
///
/// 覆盖本轮最容易被写错的一件事：**注入是否真的覆盖了订阅里的同名键**。
/// 夹具订阅刻意带上一套「错误」的 `tun` / `dns`（`stack: system`、`device: utun99`、
/// `dns-hijack: 1.1.1.1:53`、`enhanced-mode: redir-host`、`listen: 0.0.0.0:53`），
/// 生成结果必须是 App 决定的那一套。
@MainActor
enum TunConfigHarness {

    private static let injectedMixedPort = 17890
    private static let injectedControllerPort = 19090
    private static let injectedDNSListenPort = 15353

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CLASH_TUN_CONFIG_HARNESS"] != nil else { return }
        var failures = 0
        failures += run()
        print(failures == 0 ? "HARNESS DONE failures=0" : "HARNESS DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func report(_ name: String, _ passed: Bool, _ detail: String = "") -> Int {
        print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
        return passed ? 0 : 1
    }

    private static func run() -> Int {
        var failures = 0

        let directory = URL.temporaryDirectory
            .appending(path: "clash-tun-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileURL = directory.appending(path: "profile.yaml")
        do {
            try Data(fixtureProfile.utf8).write(to: profileURL)
        } catch {
            print("FAIL fixture-write \(error.localizedDescription)")
            return 1
        }

        let secret = RuntimeConfigBuilder.makeSecret()
        let common = RuntimeConfigBuilder.Injected(
            mixedPort: injectedMixedPort,
            allowLAN: false,
            controllerPort: injectedControllerPort,
            dnsPort: injectedDNSListenPort,
            secret: secret,
            logLevel: "info"
        )

        // 1. TUN 开
        var injectedOn = common
        injectedOn.tunEnabled = true
        injectedOn.tunStack = .gvisor

        let yamlOn: String
        do {
            yamlOn = try RuntimeConfigBuilder.yaml(from: profileURL, injected: injectedOn)
        } catch {
            print("FAIL build-on \(error.localizedDescription)")
            return 1
        }

        print("---- TUN 模式生成的运行配置（secret 已打码）----")
        print(redacted(yamlOn, secret: secret))
        print("---- 自检 ----")

        guard let on = normalized(yamlOn) else {
            print("FAIL parse-on 生成结果无法重新解析")
            return 1
        }

        let tunOn = on["tun"] as? [String: Any] ?? [:]
        failures += report("tun-enable", bool(tunOn["enable"]) == true, "\(String(describing: tunOn["enable"]))")
        failures += report("tun-stack", tunOn["stack"] as? String == "gvisor", "\(String(describing: tunOn["stack"]))")
        failures += report("tun-auto-route", bool(tunOn["auto-route"]) == true)
        failures += report("tun-auto-detect-interface", bool(tunOn["auto-detect-interface"]) == true)
        failures += report(
            "tun-dns-hijack",
            (tunOn["dns-hijack"] as? [String]) == ["any:53"],
            "\(String(describing: tunOn["dns-hijack"]))"
        )
        failures += report("tun-device-dropped", tunOn["device"] == nil, "device 没被丢掉")

        let dnsOn = on["dns"] as? [String: Any] ?? [:]
        failures += report("dns-enable", bool(dnsOn["enable"]) == true)
        failures += report("dns-enhanced-mode", dnsOn["enhanced-mode"] as? String == "fake-ip", "\(String(describing: dnsOn["enhanced-mode"]))")
        failures += report("dns-fake-ip-range", dnsOn["fake-ip-range"] as? String == "198.18.0.1/16", "\(String(describing: dnsOn["fake-ip-range"]))")
        failures += report(
            "dns-listen-loopback",
            dnsOn["listen"] as? String == "127.0.0.1:\(injectedDNSListenPort)",
            "\(String(describing: dnsOn["listen"]))"
        )
        failures += report("dns-nameserver-kept", (dnsOn["nameserver"] as? [String]) == ["223.5.5.5"])
        failures += report("mixed-port-injected", int(on["mixed-port"]) == injectedMixedPort)
        failures += report("allow-lan-injected", bool(on["allow-lan"]) == false)
        failures += report("secret-injected", on["secret"] as? String == secret)
        failures += report("proxies-untouched", (on["proxies"] as? [String])?.isEmpty == true)
        failures += report("rules-untouched", (on["rules"] as? [String]) == ["MATCH,DIRECT"])

        // 2. TUN 关：tun 段只剩 enable=false，DNS 不强制 fake-ip
        var injectedOff = common
        injectedOff.tunEnabled = false

        let yamlOff: String
        do {
            yamlOff = try RuntimeConfigBuilder.yaml(from: profileURL, injected: injectedOff)
        } catch {
            print("FAIL build-off \(error.localizedDescription)")
            return 1
        }

        print("---- 非 TUN 模式（只校验 tun / dns 段）----")
        print(redacted(section(of: yamlOff, start: "tun:", end: "rules:"), secret: secret))
        print("---- 自检 ----")

        guard let off = normalized(yamlOff) else {
            print("FAIL parse-off 生成结果无法重新解析")
            return 1
        }

        let tunOff = off["tun"] as? [String: Any] ?? [:]
        failures += report("off-tun-enable", bool(tunOff["enable"]) == false)
        failures += report("off-tun-only-enable", tunOff.count == 1, "多余键=\(tunOff.keys.sorted())")
        let dnsOff = off["dns"] as? [String: Any] ?? [:]
        failures += report(
            "off-dns-kept-subscription",
            dnsOff["enhanced-mode"] as? String == "redir-host",
            "\(String(describing: dnsOff["enhanced-mode"]))"
        )
        failures += report(
            "off-dns-listen-still-loopback",
            dnsOff["listen"] as? String == "127.0.0.1:\(injectedDNSListenPort)"
        )

        return failures
    }

    // MARK: - 夹具

    /// 刻意与注入值冲突的订阅正文（模拟机场自带 tun / dns）
    private static let fixtureProfile = """
    mixed-port: 1080
    allow-lan: true
    mode: global
    tun:
      enable: false
      stack: system
      auto-route: false
      auto-detect-interface: false
      dns-hijack:
        - 1.1.1.1:53
      device: utun99
      mtu: 1500
    dns:
      enable: false
      enhanced-mode: redir-host
      fake-ip-range: 10.0.0.1/8
      listen: 0.0.0.0:53
      nameserver:
        - 223.5.5.5
    proxies: []
    rules:
      - MATCH,DIRECT
    """

    // MARK: - 工具

    private static func normalized(_ yaml: String) -> [String: Any]? {
        guard let loaded = try? Yams.load(yaml: yaml) else { return nil }
        return normalize(loaded) as? [String: Any]
    }

    private static func normalize(_ value: Any) -> Any {
        if let mapping = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
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

    private static func bool(_ value: Any?) -> Bool? { value as? Bool }
    private static func int(_ value: Any?) -> Int? { value as? Int }

    /// secret 一律打码：自检输出会被贴进对话 / 日志
    private static func redacted(_ text: String, secret: String) -> String {
        text.replacingOccurrences(of: secret, with: "***")
    }

    /// 从整份 YAML 里截一段（`start` 行到 `end` 行之前），用于展示非 TUN 模式的 tun / dns
    private static func section(of yaml: String, start: String, end: String) -> String {
        var lines: [String] = []
        var collecting = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(start) { collecting = true }
            if collecting, line.hasPrefix(end) { break }
            if collecting { lines.append(String(line)) }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
