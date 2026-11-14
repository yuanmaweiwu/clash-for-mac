import Foundation
import Observation

/// 「网络检测」四个固定目标的真实探测（`docs/02-UI-SPEC.md` §3.2 / §4.11）。
///
/// 口径：
/// - 用 `URLSession` 直接发只读 `HEAD`，**不走 App 自己的 API 客户端**：测的是本机到目标
///   的端到端延迟（系统代理 / TUN 开着时自然被接管）
/// - 单目标 5s 超时；四个并发，先回来的先回填，不等最慢的那个
/// - 结果只有「通 / 超时」两态：连接失败、TLS 失败、5s 未响应、非 2xx/3xx 都归入超时，
///   不编造「成功但很慢」
@MainActor
@Observable
final class NetworkProbeService {

    /// 四个固定目标（顺序即磁贴顺序）
    enum Target: String, CaseIterable, Identifiable, Sendable {
        case google
        case github
        case apple
        case youtube

        var id: String { rawValue }

        /// 磁贴标题：品牌名保持原文
        var name: String {
            switch self {
            case .google: "Google"
            case .github: "GitHub"
            case .apple: "Apple"
            case .youtube: "YouTube"
            }
        }

        /// 端到端探测地址：`generate_204` 只回 204、无正文，最省流量
        var probeURL: URL {
            switch self {
            case .google: URL(string: "https://www.google.com/generate_204")!
            case .github: URL(string: "https://github.com")!
            case .apple: URL(string: "https://www.apple.com/library/test/success.html")!
            case .youtube: URL(string: "https://www.youtube.com/generate_204")!
            }
        }
    }

    /// 单目标状态：未测 / 测速中 / 通（毫秒）/ 超时
    enum State: Equatable, Sendable {
        case idle
        case testing
        case reachable(milliseconds: Int)
        case timeout
    }

    /// 请求超时（§3.2：5s）；探测在非隔离上下文跑，这里必须 `nonisolated`
    nonisolated static let timeout: TimeInterval = 5
    /// 自动重测的陈旧阈值：面板每次显示时超过 60s 未测就测一次
    nonisolated static let staleInterval: TimeInterval = 60

    private(set) var states: [Target: State]
    /// 上一次跑完整轮的时间；`nil` = 本次运行还没测过
    private(set) var lastTestedAt: Date?
    private(set) var isTesting = false

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        states = Dictionary(uniqueKeysWithValues: Target.allCases.map { ($0, State.idle) })
    }

    func state(for target: Target) -> State {
        states[target] ?? .idle
    }

    /// 面板显示时调用：超过 60s 未测（或从没测过）就自动测一轮
    func testIfStale(now: Date = Date()) {
        guard !isTesting else { return }
        guard let lastTestedAt else {
            testAll()
            return
        }
        guard now.timeIntervalSince(lastTestedAt) >= Self.staleInterval else { return }
        testAll()
    }

    /// 并发测四个目标；已在测时忽略（防连点叠出多轮、结果互相覆盖）
    func testAll() {
        guard !isTesting else { return }
        isTesting = true
        for target in Target.allCases {
            states[target] = .testing
        }
        task?.cancel()

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isTesting = false }

            await withTaskGroup(of: (Target, State).self) { group in
                for target in Target.allCases {
                    group.addTask {
                        (target, await NetworkProbeService.probe(target))
                    }
                }
                for await (target, state) in group {
                    guard !Task.isCancelled else { return }
                    self.states[target] = state
                }
            }

            guard !Task.isCancelled else { return }
            self.lastTestedAt = Date()
        }
    }

    // MARK: - 探测

    /// 只读 `HEAD`：不下载正文，量的是建连 + 首包往返
    private nonisolated static func probe(_ target: Target) async -> State {
        var request = URLRequest(url: target.probeURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        // 命中缓存就不叫「端到端延迟」了
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = clock.now - start
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode)
            else { return .timeout }
            return .reachable(milliseconds: milliseconds(elapsed))
        } catch {
            return .timeout
        }
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}

#if DEBUG
extension NetworkProbeService {
    /// 截图夹具：摆出四种状态，便于一次看全（不发起真实请求）
    func applyPreviewStates() {
        states = [
            .google: .reachable(milliseconds: 68),
            .github: .reachable(milliseconds: 214),
            .apple: .reachable(milliseconds: 46),
            .youtube: .timeout
        ]
        lastTestedAt = Date()
    }
}
#endif
