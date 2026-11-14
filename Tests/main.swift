import Darwin
import Foundation
import Yams

// 极简单测入口：`bash Scripts/unit-tests.sh` 编译并运行。
//
// 不引 XCTest / 第三方依赖：断言就是下面两个 `expect*`，失败计数进退出码。
// 每个 group 一个函数，只覆盖**纯函数**；涉及网络 / AppKit / 真实套接字业务的
// 一律不进这里（`PortAllocator` 只用真实 socket 做「占用 → 不可用」这一条）。

// MARK: - 断言

private nonisolated(unsafe) var checks = 0
private nonisolated(unsafe) var failures = 0

func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    guard condition else {
        failures += 1
        print("  FAIL \(what)  (main.swift:\(line))")
        return
    }
    print("  ok   \(what)")
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
    checks += 1
    guard actual == expected else {
        failures += 1
        print("  FAIL \(what)  (main.swift:\(line))")
        print("         期望：\(expected)")
        print("         实际：\(actual)")
        return
    }
    print("  ok   \(what)")
}

func group(_ name: String, _ body: () async throws -> Void) async {
    print("\n== \(name) ==")
    do {
        try await body()
    } catch {
        failures += 1
        print("  FAIL 抛错：\(error)")
    }
}

// MARK: - YAML 读取（断言用；只读不改）

/// Yams 的映射是 `[AnyHashable: Any]`，统一成 `[String: Any]` 好取值
private func normalize(_ value: Any) -> Any {
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

private func parseYAML(_ text: String) -> [String: Any] {
    guard let loaded = try? Yams.load(yaml: text),
          let root = normalize(loaded) as? [String: Any] else {
        return [:]
    }
    return root
}

private func dict(_ root: [String: Any], _ key: String) -> [String: Any] {
    root[key] as? [String: Any] ?? [:]
}

// MARK: - 1. RuntimeConfigBuilder 注入

private let sampleProfile = """
mixed-port: 1234
port: 7891
socks-port: 7892
allow-lan: true
bind-address: 0.0.0.0
mode: global
log-level: debug
secret: old-secret
external-controller: 0.0.0.0:9999
profile:
  store-selected: false
  store-fake-ip: false
dns:
  enable: false
  listen: 0.0.0.0:53
  nameserver:
    - 8.8.8.8
tun:
  enable: true
  stack: system
  device: utun1024
proxies:
  - name: HK
    type: ss
proxy-groups:
  - name: 手动
    type: select
rules:
  - MATCH,DIRECT
"""

/// 写一份订阅正文到临时文件（`yaml(from:)` 走的是「读文件 → 注入」的真实入口）
private func temporaryProfile(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "clash-unittest-profile-\(UUID().uuidString).yaml")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func testRuntimeConfigInjection() async throws {
    let profileURL = try temporaryProfile(sampleProfile)
    defer { try? FileManager.default.removeItem(at: profileURL) }

    let injected = RuntimeConfigBuilder.Injected(
        allowLAN: false,
        controllerPort: 9090,
        dnsPort: 1053,
        secret: "new-secret"
    )
    let yaml = try await RuntimeConfigBuilder.yaml(from: profileURL, injected: injected)
    let root = parseYAML(yaml)

    expectEqual(root["mixed-port"] as? Int, 7890, "混合端口被注入值覆盖（原 1234）")
    expect(root["port"] == nil, "旧式 http 端口被删除")
    expect(root["socks-port"] == nil, "旧式 socks 端口被删除")
    expectEqual(root["allow-lan"] as? Bool, false, "allow-lan 跟随注入值")
    expectEqual(root["bind-address"] as? String, "127.0.0.1", "关掉 allow-lan 时绑回环")
    expectEqual(root["mode"] as? String, "rule", "mode 覆盖订阅里的 global")
    expectEqual(root["log-level"] as? String, "info", "log-level 取注入值（默认 info）")
    expectEqual(root["secret"] as? String, "new-secret", "secret 被注入值覆盖")
    expectEqual(root["external-controller"] as? String, "127.0.0.1:9090", "控制端口固定回环")

    let profile = dict(root, "profile")
    expectEqual(profile["store-selected"] as? Bool, true, "profile.store-selected 强制 true")
    expectEqual(profile["store-fake-ip"] as? Bool, true, "profile.store-fake-ip 强制 true")

    let dns = dict(root, "dns")
    expectEqual(dns["enable"] as? Bool, true, "dns.enable 强制 true")
    expectEqual(dns["listen"] as? String, "127.0.0.1:1053", "dns 只监听回环 + 注入端口")
    expectEqual(dns["nameserver"] as? [String], ["8.8.8.8"], "非 TUN 时保留订阅的 nameserver")
    expect(dns["enhanced-mode"] == nil, "非 TUN 不注入 fake-ip")

    let tun = dict(root, "tun")
    expectEqual(tun.count, 1, "TUN 关闭时 tun 段整段替换")
    expectEqual(tun["enable"] as? Bool, false, "tun.enable = false")
    expect(tun["device"] == nil && tun["stack"] == nil, "订阅里的 tun 配置不复用")

    expectEqual((root["rules"] as? [Any])?.count, 1, "rules 原样保留")
    expectEqual((root["proxies"] as? [[String: Any]])?.first?["name"] as? String, "HK", "proxies 原样保留")
    expectEqual((root["proxy-groups"] as? [[String: Any]])?.first?["name"] as? String, "手动", "proxy-groups 原样保留")

    let untouched = try String(contentsOf: profileURL, encoding: .utf8)
    expectEqual(untouched, sampleProfile, "用户配置正文不被改写")

    // TUN 打开：整段换成 App 决定的值 + 强制 fake-ip，但订阅的 nameserver 仍保留
    var tunInjected = injected
    tunInjected.tunEnabled = true
    let tunYAML = parseYAML(try await RuntimeConfigBuilder.yaml(from: profileURL, injected: tunInjected))
    let tunSection = dict(tunYAML, "tun")
    expectEqual(tunSection["enable"] as? Bool, true, "TUN 开：tun.enable = true")
    expectEqual(tunSection["stack"] as? String, "gvisor", "TUN 开：栈由 App 决定（默认 gvisor）")
    expectEqual(tunSection["auto-route"] as? Bool, true, "TUN 开：auto-route")
    expectEqual(tunSection["auto-detect-interface"] as? Bool, true, "TUN 开：auto-detect-interface")
    expectEqual(tunSection["dns-hijack"] as? [String], ["any:53"], "TUN 开：劫持 53")
    expect(tunSection["device"] == nil, "TUN 开：订阅里的 device 被丢弃")

    let tunDNS = dict(tunYAML, "dns")
    expectEqual(tunDNS["enhanced-mode"] as? String, "fake-ip", "TUN 开：强制 fake-ip")
    expectEqual(tunDNS["fake-ip-range"] as? String, "198.18.0.1/16", "TUN 开：fake-ip 网段")
    expectEqual(tunDNS["nameserver"] as? [String], ["8.8.8.8"], "TUN 开：订阅 nameserver 优先")

    // 没有 nameserver 的订阅：TUN 下必须兜底，否则 DNS 直接不可用
    let bareURL = try temporaryProfile("proxies: []\ndns:\n  enable: false\n")
    defer { try? FileManager.default.removeItem(at: bareURL) }
    let bareDNS = dict(parseYAML(try await RuntimeConfigBuilder.yaml(from: bareURL, injected: tunInjected)), "dns")
    expectEqual(bareDNS["nameserver"] as? [String], RuntimeConfigBuilder.defaultNameServers, "TUN 缺 nameserver 时注入兜底")

    // 解析失败：归到 configInvalid，且不回显 YAML 正文（里面有节点密码）
    let brokenURL = try temporaryProfile("rules: [unclosed\n")
    defer { try? FileManager.default.removeItem(at: brokenURL) }
    do {
        _ = try await RuntimeConfigBuilder.yaml(from: brokenURL, injected: injected)
        expect(false, "坏 YAML 应抛 configInvalid")
    } catch let error as KernelError {
        if case .configInvalid = error {
            expect(true, "坏 YAML 抛 configInvalid")
        } else {
            expect(false, "坏 YAML 抛 configInvalid（实际 \(error)）")
        }
    } catch {
        expect(false, "坏 YAML 抛 KernelError（实际 \(error)）")
    }

    // 没有订阅：最小可用配置（v0.1 行为）
    let minimal = parseYAML(try await RuntimeConfigBuilder.yaml(from: nil, injected: injected))
    expectEqual(minimal["mixed-port"] as? Int, 7890, "无订阅：仍注入混合端口")
    expectEqual(minimal["secret"] as? String, "new-secret", "无订阅：仍注入 secret")
    expectEqual(dict(minimal, "tun")["enable"] as? Bool, false, "无订阅：TUN 关闭")
    expectEqual(dict(minimal, "dns")["listen"] as? String, "127.0.0.1:1053", "无订阅：仍注入 dns 监听")
}

// MARK: - 2. SubscriptionFetcher 响应头解析

private func testSubscriptionHeaderParsing() {
    let full = SubscriptionFetcher.parseUserInfo("upload=1; download=2; total=3; expire=4")
    expectEqual(full?.upload, 1, "userinfo：upload")
    expectEqual(full?.download, 2, "userinfo：download")
    expectEqual(full?.total, 3, "userinfo：total")
    expectEqual(full?.expire, 4, "userinfo：expire")

    let partial = SubscriptionFetcher.parseUserInfo("total=1099511627776")
    expectEqual(partial?.total, 1_099_511_627_776, "userinfo：超过 32 位的大数")
    expect(partial?.upload == nil && partial?.download == nil && partial?.expire == nil, "userinfo：缺字段为 nil")

    let spaced = SubscriptionFetcher.parseUserInfo(" upload = 12 ; download = 34 ; expire=1700000000 ; foo=9")
    expectEqual(spaced?.upload, 12, "userinfo：容忍空格")
    expectEqual(spaced?.download, 34, "userinfo：容忍空格（download）")
    expectEqual(spaced?.expire, 1_700_000_000, "userinfo：expire 时间戳")
    expect(SubscriptionFetcher.parseUserInfo(nil) == nil, "userinfo：头缺失为 nil")
    expect(SubscriptionFetcher.parseUserInfo("") == nil, "userinfo：空头为 nil")

    let garbage = SubscriptionFetcher.parseUserInfo("upload=abc; download")
    expect(garbage?.upload == nil && garbage?.download == nil, "userinfo：非数字 / 缺等号按缺字段处理")

    expectEqual(
        SubscriptionFetcher.parseFileName("attachment; filename=\"My Sub.yaml\""),
        "My Sub",
        "filename：去引号去扩展名"
    )
    expectEqual(
        SubscriptionFetcher.parseFileName("attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.yaml"),
        "中文",
        "filename*：百分号解码 + 去扩展名"
    )
    expectEqual(
        SubscriptionFetcher.parseFileName("attachment; filename=\"plain.YAML\""),
        "plain",
        "filename：大写扩展名也去掉"
    )
    expectEqual(
        SubscriptionFetcher.parseFileName("attachment; filename=\"a.txt\"; filename*=UTF-8''%E9%93%BE%E6%8E%A5"),
        "链接",
        "filename* 优先于 filename"
    )
    expectEqual(SubscriptionFetcher.parseFileName("attachment; filename=\"line\nbreak.yaml\""), "line break", "filename：清洗换行")
    expectEqual(SubscriptionFetcher.parseFileName("inline"), nil, "filename：头里没有 filename 返回 nil")
    expectEqual(SubscriptionFetcher.parseFileName(nil), nil, "filename：头缺失返回 nil")

    let long = String(repeating: "长", count: 300)
    expectEqual(SubscriptionFetcher.parseFileName("attachment; filename=\"\(long).yaml\""), long, "filename：超长名不截断")
}

// MARK: - 3. 日志脱敏

private func testLogRedaction() async {
    func redact(_ text: String) async -> String {
        LogRedactor.redactCredentials(in: text)
    }

    let url = "GET https://api.test/x?token=abc123&page=1"
    let redacted = await redact(url)
    expect(redacted.contains("token=***"), "URL token 被打码")
    expect(!redacted.contains("abc123"), "URL token 原文不残留")
    expect(redacted.contains("page=1"), "非敏感参数原样保留")

    expectEqual(
        await redact("https://sub.test/link?secret=deadbeef&flag=clash"),
        "https://sub.test/link?secret=***&flag=clash",
        "订阅链接的 secret 被打码"
    )
    expectEqual(
        await redact("GET /x?access_token=zzz"),
        "GET /x?access_token=***",
        "access_token 被打码"
    )
    expectEqual(await redact("GET /x?TOKEN=UPPER"), "GET /x?TOKEN=***", "大小写不敏感")
    expectEqual(
        await redact("\"token=quoted\""),
        "\"token=***\"",
        "引号前缀也能识别"
    )

    let benign = "GET /version 200 内核未响应"
    expectEqual(await redact(benign), benign, "无敏感内容原样返回")
    expectEqual(await redact("日志 token: abc"), "日志 token: abc", "正文里的 token: 不误伤")

    let once = await redact(url)
    expectEqual(await redact(once), once, "脱敏幂等")
}

// MARK: - 4. 信息节点过滤

private func testInfoNodeFilter() {
    for builtin in ProxyNodeFilter.builtinNames.sorted() {
        expect(!ProxyNodeFilter.isInfoNode(builtin), "内置策略不过滤：\(builtin)")
    }
    expect(!ProxyNodeFilter.isInfoNode("direct"), "内置判定大小写敏感（与内核返回一致）")

    expect(!ProxyNodeFilter.isInfoNode("香港 01 | IPLC"), "真实节点名不过滤")
    expect(!ProxyNodeFilter.isInfoNode("🇯🇵 东京 · 家宽 02"), "带表情的节点名不过滤")
    expect(!ProxyNodeFilter.isInfoNode(""), "空名字不过滤")

    expect(ProxyNodeFilter.isInfoNode("到期时间：不限时"), "「到期」命中")
    expect(ProxyNodeFilter.isInfoNode("剩余流量：128.00G"), "「剩余流量」命中")
    expect(ProxyNodeFilter.isInfoNode("已用：103.09G，总共：128.00G"), "「已用 / 总共」命中")
    expect(ProxyNodeFilter.isInfoNode("官网：example.com"), "「官网」命中")
    expect(ProxyNodeFilter.isInfoNode("Website: example.com"), "英文关键词不区分大小写")
    expect(ProxyNodeFilter.isInfoNode("EXPIRED 2026-01-01"), "expire 词根命中")
    expect(ProxyNodeFilter.isInfoNode("Traffic Info"), "traffic 命中")

    // 大量调用后仍只编译过一次正则（重复编译是这条过滤的旧性能坑）
    for _ in 0 ..< 2000 {
        _ = ProxyNodeFilter.isInfoNode("香港 01")
    }
    #if DEBUG
    expectEqual(ProxyNodeFilter.debugCompileCount, 1, "关键词正则进程内只编译一次")
    #else
    print("  skip 正则编译次数（需要 -DDEBUG 编译）")
    #endif
}

// MARK: - 5. 端口判定

/// 占住一个临时端口，验证 `isAvailable` 能识别「真有人在监听」
private final class ListeningPort {
    private var descriptor: Int32 = -1
    let port: Int

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }

        var actual = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }

        descriptor = fd
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

private func testPortJudgement() {
    expect(!PortAllocator.isAvailable(port: 0), "端口 0 非法 → 不可用")
    expect(!PortAllocator.isAvailable(port: 65_536), "越界端口 → 不可用")
    expect(!PortAllocator.isAvailable(port: -1), "负数端口 → 不可用")

    guard let occupied = ListeningPort() else {
        print("  skip 真实 socket 部分（无法建监听 socket）")
        return
    }
    expect(!PortAllocator.isAvailable(port: occupied.port), "被占用端口 → 不可用")
    let freedPort = occupied.port
    occupied.release()
    expect(PortAllocator.isAvailable(port: freedPort), "释放后同一端口 → 可用")

    guard let allocated = try? PortAllocator.allocate() else {
        expect(false, "allocate() 取到端口")
        return
    }
    expect((1 ... 65_535).contains(allocated), "allocate() 落在合法区间（\(allocated)）")
    expect(PortAllocator.isAvailable(port: allocated), "刚分配的端口可用")

    let distinct = (try? PortAllocator.allocateDistinct(3)) ?? []
    expectEqual(distinct.count, 3, "allocateDistinct(3) 返回 3 个")
    expectEqual(Set(distinct).count, 3, "allocateDistinct 互不重复")
    expect(distinct.allSatisfy { PortAllocator.isAvailable(port: $0) }, "allocateDistinct 全部可用")
}

// MARK: - 入口

print("Clash 纯函数单测")

await group("RuntimeConfigBuilder 注入") { try await testRuntimeConfigInjection() }
await group("SubscriptionFetcher 响应头解析") { testSubscriptionHeaderParsing() }
await group("LogRedactor 脱敏") { await testLogRedaction() }
await group("ProxyNodeFilter 信息节点") { testInfoNodeFilter() }
await group("PortAllocator 端口判定") { testPortJudgement() }

print("\n\(checks - failures) 项通过，\(failures) 项失败（共 \(checks) 项）")
exit(failures == 0 ? 0 : 1)
