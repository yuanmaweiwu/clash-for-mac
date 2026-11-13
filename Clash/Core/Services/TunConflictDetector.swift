import Foundation
import OSLog

/// 另一个客户端已经在接管流量（Clash Verge / 别的 VPN 的 TUN）。
///
/// 两家 TUN 同时开的结果不是「都生效」，而是**互相抢默认路由**：谁后写谁赢，
/// 输的那个内核还在跑但流量全走对方，用户看到的是「TUN 已开启但打不开网页」。
/// 所以宁可拒绝启动，并把「关掉谁」说清楚。
struct TunConflict: Equatable, Sendable {
    /// 冲突所在的接口（`utunN`）
    let interface: String
    /// 给日志 / banner 的一句话，例如「默认路由已指向 utun3」
    let summary: String

    var userMessage: String {
        "检测到其它客户端的 TUN/VPN 正在运行（\(summary)），请先关闭后再开启 TUN"
    }
}

/// 启动前检测「别家 TUN 是否已经在接管流量」。
///
/// 判据（任一命中即冲突，全部只读）：
/// 1. 默认路由的接口是 `utun*` —— 流量已经被某条隧道接管
/// 2. 某个 `utun*` 上配置了 IPv4 地址 —— 活跃隧道（系统自带的空壳 utun 没有地址，
///    本机常驻的 `utun0-3` 就属于这种，不能误判）
///
/// 不做的事：不 kill 别家进程、不 bootout 别家 LaunchDaemon、不自动改路由。
enum TunConflictDetector {

    private static let logger = Logger(subsystem: "com.clash.app", category: "tun")
    private static let ifconfigPath = "/sbin/ifconfig"

    static func detect() -> TunConflict? {
        let snapshot = SystemNetworkProbe.capture()
        if let interface = snapshot.defaultInterface, interface.hasPrefix("utun") {
            return TunConflict(interface: interface, summary: "默认路由已指向 \(interface)")
        }

        if let tunnel = activeTunnels().first {
            return TunConflict(interface: tunnel.interface, summary: "\(tunnel.interface) 已配置 \(tunnel.address)")
        }
        return nil
    }

    // MARK: - 接口扫描

    private struct ActiveTunnel {
        let interface: String
        let address: String
    }

    /// `ifconfig -a` 里「`utunN:` 段落中出现 `inet x.x.x.x`」的接口
    private static func activeTunnels() -> [ActiveTunnel] {
        guard let output = SystemNetworkProbe.runCommand(ifconfigPath, ["-a"]) else {
            logger.error("读取网络接口失败，跳过 TUN 冲突检测")
            return []
        }

        var results: [ActiveTunnel] = []
        var current: String?

        for line in output.split(separator: "\n") {
            let text = String(line)
            let isInterfaceHeader = !text.hasPrefix("\t") && !text.hasPrefix(" ")
            if isInterfaceHeader {
                let name = text.split(separator: ":").first.map(String.init) ?? ""
                current = name.hasPrefix("utun") ? name : nil
                continue
            }
            guard let current else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }
            let address = String(trimmed.dropFirst("inet ".count)).split(separator: " ").first.map(String.init) ?? "?"
            if !results.contains(where: { $0.interface == current }) {
                results.append(ActiveTunnel(interface: current, address: address))
            }
        }
        return results
    }
}
