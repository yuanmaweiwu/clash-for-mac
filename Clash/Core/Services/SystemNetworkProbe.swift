import Foundation
import OSLog

/// 一次网络「基线」快照：默认路由 + 系统 DNS。
///
/// TUN 会改默认路由（指向 utun）；关 TUN 后如果路由没回去，用户的流量会进一个不存在的
/// 隧道——表现就是「断网且没有 UI 可救」。所以开启前抓一份基线，关闭后对比，
/// 不一致就把原因写进面板 banner，而不是假装成功。
///
/// 只用只读命令：`/sbin/route -n get default` 与 `/etc/resolv.conf`，不改任何系统设置。
struct SystemNetworkSnapshot: Equatable, Sendable {

    /// `interface: en0`；没有默认路由时为 nil（例如只有 TUN 的时候）
    let defaultInterface: String?
    /// `gateway: 192.168.1.1`；点对点链路（utun）通常没有
    let defaultGateway: String?
    /// `resolv.conf` 里的 nameserver 列表，按出现顺序
    let nameServers: [String]
    /// 接管默认路由的拆分路由（mihomo 用 `0/1` + `128.0/1`），例如 `128.0/1 utun4`
    let tunnelRoutes: [String]

    /// 与基线对比，返回给用户看的中文差异；完全一致 → nil
    func differences(from baseline: SystemNetworkSnapshot) -> [String] {
        var messages: [String] = []

        if defaultInterface != baseline.defaultInterface {
            let current = defaultInterface ?? "无"
            let expected = baseline.defaultInterface ?? "无"
            messages.append("默认路由接口为 \(current)（原为 \(expected)）")
        }
        if defaultGateway != baseline.defaultGateway {
            let current = defaultGateway ?? "无"
            let expected = baseline.defaultGateway ?? "无"
            messages.append("默认网关为 \(current)（原为 \(expected)）")
        }
        if nameServers != baseline.nameServers {
            let current = nameServers.isEmpty ? "无" : nameServers.joined(separator: "、")
            messages.append("系统 DNS 为 \(current)")
        }
        if tunnelRoutes != baseline.tunnelRoutes {
            let current = tunnelRoutes.isEmpty ? "已清空" : tunnelRoutes.joined(separator: "、")
            messages.append("仍有 TUN 分流路由（\(current)）")
        }
        return messages
    }
}

/// 读取 / 对比系统网络基线（只读，不做任何修改）
enum SystemNetworkProbe {

    private static let logger = Logger(subsystem: "com.clash.app", category: "tun")
    private static let routePath = "/sbin/route"
    private static let resolvConfPath = "/etc/resolv.conf"
    /// 只读命令正常 <100ms；给 3s 上限，进程卡住时杀掉，避免整个 App 挂死
    private static let commandTimeout: TimeInterval = 3

    /// UI 路径（开 / 关 TUN）：三个只读命令在后台跑，主线程只拿结果做对比。
    static func capture() async -> SystemNetworkSnapshot {
        await Task.detached(priority: .userInitiated) {
            captureSynchronously()
        }.value
    }

    /// **同步版本只给退出路径**（`willTerminate` / 信号处理）：那里无法 `await`，
    /// 又必须在进程消失前拿到还原判断。UI 路径一律用 `capture()`。
    static func captureSynchronously() -> SystemNetworkSnapshot {
        let route = defaultRoute()
        return SystemNetworkSnapshot(
            defaultInterface: route.interface,
            defaultGateway: route.gateway,
            nameServers: nameServers(),
            tunnelRoutes: tunnelRoutes()
        )
    }

    // MARK: - 默认路由

    private static func defaultRoute() -> (interface: String?, gateway: String?) {
        // 没有默认路由时 route 退出码非 0，输出为空 → 两个字段都是 nil
        guard let output = runCommandSynchronously(routePath, ["-n", "get", "default"]) else {
            return (nil, nil)
        }
        return (
            value(of: "interface", in: output),
            value(of: "gateway", in: output)
        )
    }

    /// 解析 `key: value` 形式的行（`route -n get` 的输出固定用这个格式）
    private static func value(of key: String, in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            let raw = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    // MARK: - 分流路由

    /// `0/1`、`128.0/1` 这两条是 mihomo / 别家 TUN 接管默认路由的典型手法（不改 `default`）
    private static func tunnelRoutes() -> [String] {
        guard let table = runCommandSynchronously("/usr/sbin/netstat", ["-rn", "-f", "inet"]) else { return [] }
        return table.split(separator: "\n").compactMap { line in
            let fields = String(line).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let destination = fields.first else { return nil }
            guard destination == "0/1" || destination == "128.0/1" else { return nil }
            let interface = fields.last ?? "?"
            return "\(destination) → \(interface)"
        }
    }

    // MARK: - DNS

    private static func nameServers() -> [String] {
        guard let text = try? String(contentsOfFile: resolvConfPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("nameserver") else { return nil }
            let value = String(trimmed.dropFirst("nameserver".count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    // MARK: - 进程

    /// 异步跑一个只读命令；输出合并 stdout / stderr，失败返回 nil。
    /// `internal` 供 `TunConflictDetector` 复用（不重复实现 Process 管道）。
    static func runCommand(_ path: String, _ arguments: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) {
            runCommandSynchronously(path, arguments)
        }.value
    }

    /// 同步执行（`captureSynchronously` / 退出路径用），带 3s 超时。
    /// 用 `terminationHandler` + 信号量等退出：轮询 `isRunning` 会白等 ~100ms/条命令。
    static func runCommandSynchronously(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            logger.error("执行 \(path, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }

        if finished.wait(timeout: .now() + commandTimeout) == .timedOut {
            logger.error("执行 \(path, privacy: .public) 超过 \(Int(commandTimeout))s，已终止")
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
