import Foundation
import Observation

/// 实时流量：`/traffic` WS 采样 → 60 点环形缓冲（`docs/01-ARCHITECTURE.md` §8）。
///
/// 边界：
/// - 只在内核 `running` 时连接；`stopped` / `failed` 清空序列并断开
/// - 断线自动重连 1s → 2s → 4s → 8s 封顶，**重连期间保留曲线**（`isStreaming = false`，
///   UI 走 §4.5 断连态：曲线 30% 透明、数值 `—`）
/// - 端口 / secret 变了（内核重启）→ 用新的 `ClashAPIClient` 重建连接，不复用旧 socket
/// - 连接常驻：面板是 `MenuBarExtra` 浮层，可见性拿不到可靠信号，因此内核 running 期间
///   始终保留一条 WS；不做「隐藏 30s 断开」，避免每次开面板都重新握手、曲线从空开始
@MainActor
@Observable
final class TrafficService {

    /// 曲线窗口：60 点 / 1Hz（§4.5）
    static let sampleCount = 60

    /// 当前下行 / 上行速率（字节 / 秒）
    private(set) var down: Double = 0
    private(set) var up: Double = 0
    /// 60 点窗口，末位是最新采样（字节 / 秒）
    private(set) var downSeries: [Double] = Array(repeating: 0, count: sampleCount)
    private(set) var upSeries: [Double] = Array(repeating: 0, count: sampleCount)
    /// WS 在线：状态条显示实时速率；断连后数值回到 `—`
    private(set) var isStreaming = false
    /// 是否收到过采样：没有采样走「暂无流量」空态，有采样就画曲线（断连时半透明）
    private(set) var hasSamples = false

    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// 串行链代号：内核重启后旧循环的收尾不覆盖新循环
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var client: ClashAPIClient?

    init(kernel: KernelService) {
        self.kernel = kernel
    }

    // MARK: - 生命周期

    /// 内核 `running`：幂等地建立连接（已在跑就不重开）
    func start() {
        guard runTask == nil, kernel.phase == .running else { return }

        runID += 1
        let id = runID
        runTask = Task { [weak self] in
            await self?.run(id: id)
        }
    }

    /// 内核停止 / 失败：断开并清空，避免下次启动显示上一次会话的波形
    func stop() {
        runTask?.cancel()
        runTask = nil

        let current = client
        client = nil
        Task { await current?.stopTraffic() }

        isStreaming = false
        hasSamples = false
        down = 0
        up = 0
        downSeries = Array(repeating: 0, count: Self.sampleCount)
        upSeries = Array(repeating: 0, count: Self.sampleCount)
    }

    // MARK: - 连接循环

    /// 一条连接跑到断就退避重连；内核停了 / 任务被取消就结束
    private func run(id: Int) async {
        defer {
            if runID == id { runTask = nil }
        }

        var attempt = 0
        while !Task.isCancelled {
            guard kernel.phase == .running, let port = kernel.port, let secret = kernel.secret else {
                return
            }

            let client = ClashAPIClient(port: port, secret: secret)
            self.client = client

            do {
                let stream = await client.traffic()
                for try await sample in stream {
                    guard !Task.isCancelled else { return }
                    // 收到帧 = 连接健康，下次断线从最短退避重新开始
                    attempt = 0
                    apply(sample)
                }
            } catch {
                // 握手失败 / 断流：统一走退避重连
            }

            guard !Task.isCancelled else { return }
            self.client = nil
            isStreaming = false

            attempt += 1
            try? await Task.sleep(for: Self.backoff(attempt: attempt))
        }
    }

    /// 1s → 2s → 4s → 8s 封顶（`core-process` §5）
    private static func backoff(attempt: Int) -> Duration {
        .seconds(min(1 << min(max(attempt - 1, 0), 3), 8))
    }

    private func apply(_ sample: TrafficSample) {
        let downValue = max(sample.down, 0)
        let upValue = max(sample.up, 0)

        down = downValue
        up = upValue
        push(downValue, into: &downSeries)
        push(upValue, into: &upSeries)
        hasSamples = true
        isStreaming = true
    }

    private func push(_ value: Double, into series: inout [Double]) {
        series.removeFirst()
        series.append(value)
    }
}
