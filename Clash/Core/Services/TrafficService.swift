import Foundation
import Observation

/// 实时流量：`/traffic` WS 采样 → 60 点环形缓冲（`docs/01-ARCHITECTURE.md` §8）。
///
/// 边界：
/// - 只在内核 `running` 时连接；`stopped` / `failed` 断开连接，但**保留最后一帧波形**
///   按断连态显示（内核 stop → start 的开关 / 更新订阅场景不再闪回「暂无流量」）
/// - 断线自动重连 1s → 2s → 4s → 8s 封顶，**重连期间保留曲线**（`isStreaming = false`，
///   UI 走 §4.5 断连态：曲线 30% 透明、数值 `—`）
/// - 端口 / secret 变了（内核重启）→ 用新的 `ClashAPIClient` 重建连接，不复用旧 socket
/// - 连接常驻：面板是自建 `NSPanel` 浮层，内核 running 期间始终保留一条 WS；
///   面板收起时**照常采样、但不发布**——隐藏的 `NSHostingView` 仍会跟着状态变化
///   离屏重绘，曲线每秒一次足以把 GPU 表面一直留在脏状态（实测 39MB → 95MB）
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

    // MARK: - 面板不可见时的采样（只进缓冲，不发布）

    /// 面板是否可见。默认 `true`：无人值守夹具（`SystemProxyHarness` / 预览）没有面板，
    /// 需要照常出数值；真实 App 由 `PanelWindowController` 建好后立刻声明「隐藏」。
    @ObservationIgnored private var isPanelVisible = true
    /// 缓冲窗口：可见性开关只影响「发布」，不影响采样
    @ObservationIgnored private var downBuffer: [Double] = Array(repeating: 0, count: sampleCount)
    @ObservationIgnored private var upBuffer: [Double] = Array(repeating: 0, count: sampleCount)
    @ObservationIgnored private var bufferedHasSamples = false
    @ObservationIgnored private var bufferedDown: Double = 0
    @ObservationIgnored private var bufferedUp: Double = 0
    /// WS 健康度：隐藏期间也要记，重新上屏时一次补齐 `isStreaming`
    @ObservationIgnored private var streamHealthy = false

    init(kernel: KernelService) {
        self.kernel = kernel
    }

    // MARK: - 可见性

    /// 面板显隐（唯一入口 `PanelWindowController`）。
    ///
    /// 收起时把已发布的数据清成空态：图层不再持有上一帧波形，隐藏窗口也不会因为
    /// 每秒一次的采样继续重绘；重新打开时用缓冲里的最近 60 点一次性补齐。
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible {
            publish()
        } else {
            clearPublished()
        }
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

    /// 内核停止 / 失败：断开连接并保留最后一帧波形（断连态）。
    ///
    /// 不清空采样：开关 TUN / 更新订阅都会让内核 stop → start，清空会让曲线卡在
    /// 开关瞬间闪回「暂无流量」再重新长出来。内核没跑时 `isStreaming = false`，
    /// 曲线按 §4.5 断连态降到 30%，数值回 `—`；App 下一次启动是新的 Service 实例，
    /// 不会把上一次会话的波形带过来。
    func stop() {
        runTask?.cancel()
        runTask = nil

        let current = client
        client = nil
        Task { await current?.stopTraffic() }

        streamHealthy = false
        bufferedDown = 0
        bufferedUp = 0
        isStreaming = false
        down = 0
        up = 0
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
            streamHealthy = false
            if isPanelVisible { isStreaming = false }

            attempt += 1
            try? await Task.sleep(for: Self.backoff(attempt: attempt))
        }
    }

    /// 1s → 2s → 4s → 8s 封顶（`core-process` §5）
    private static func backoff(attempt: Int) -> Duration {
        .seconds(min(1 << min(max(attempt - 1, 0), 3), 8))
    }

    private func apply(_ sample: TrafficSample) {
        bufferedDown = max(sample.down, 0)
        bufferedUp = max(sample.up, 0)

        push(bufferedDown, into: &downBuffer)
        push(bufferedUp, into: &upBuffer)
        bufferedHasSamples = true
        streamHealthy = true

        // 面板收起：只进缓冲。这里绝不能碰可观察状态——每碰一次，
        // 隐藏的 `NSHostingView` 就会离屏重画一遍曲线
        guard isPanelVisible else { return }
        publish()
    }

    /// 把缓冲一次性发布给 UI（上屏 / 每帧采样共用）
    private func publish() {
        down = bufferedDown
        up = bufferedUp
        downSeries = downBuffer
        upSeries = upBuffer
        hasSamples = bufferedHasSamples
        isStreaming = streamHealthy
    }

    /// 收起面板：曲线回到空态，图层不留在上一帧波形上
    private func clearPublished() {
        down = 0
        up = 0
        downSeries = Array(repeating: 0, count: Self.sampleCount)
        upSeries = Array(repeating: 0, count: Self.sampleCount)
        hasSamples = false
        isStreaming = false
    }

    private func push(_ value: Double, into series: inout [Double]) {
        series.removeFirst()
        series.append(value)
    }
}
