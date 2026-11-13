import Foundation
import Observation

/// 日志窗口的数据源：`/logs` WS → 500 条环形缓冲（`core-process` §5）。
///
/// 边界：
/// - **窗口打开才连，关窗即断**（`start()` / `stop()` 由 `LogWindowView` 的 appear / disappear 驱动），
///   不像流量那样后台常驻
/// - 断连不清缓冲：界面继续显示已有行，顶部提示「连接中断，正在重试…」；重连 1s → 8s 封顶
/// - 内核重启后端口 / secret 会变：每轮重连都重新读 `KernelService`，不复用旧 socket
/// - 脱敏在**写入缓冲前**完成，展示与导出共用同一份已打码文本
@MainActor
@Observable
final class LogStore {

    /// 环形缓冲上限（`core-process` 无约定，取够回溯一次操作的量）
    static let capacity = 500
    /// 请求 `level=info`：内核只推 >= info 的帧（`debug` 不推，工具行也就不放这一档）
    static let streamLevel = "info"

    /// 全部已收到的行（含被级别筛选隐藏的），超过 `capacity` 丢最旧
    private(set) var lines: [LogLine] = []
    /// 级别筛选：默认 info + warning + error
    var levelFilter: Set<LogLine.Level> = [.info, .warning, .error]
    /// 暂停：只冻结**显示**，新行照旧写入缓冲（恢复后补齐）
    private(set) var isPaused = false
    /// WS 在线
    private(set) var isConnected = false
    /// 窗口开着 = 会话在跑
    private(set) var isRunning = false

    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var client: ClashAPIClient?
    /// 暂停瞬间的缓冲快照；筛选仍作用在快照上，所以切级别不用恢复暂停
    private var pausedLines: [LogLine] = []
    /// 本会话是否成功连上过：首次握手前不喊「连接中断」，交给空态文案解释
    private var hasConnectedOnce = false

    init(kernel: KernelService) {
        self.kernel = kernel
    }

    // MARK: - 派生

    /// 界面当前该显示的行：暂停时用快照，再按级别筛选
    var visibleLines: [LogLine] {
        let source = isPaused ? pausedLines : lines
        return source.filter { levelFilter.contains($0.level) }
    }

    /// 断连提示：连上过又断了才提示（`core-process` §5：不清零已有内容）
    var showsReconnecting: Bool { isRunning && hasConnectedOnce && !isConnected }

    // MARK: - 生命周期

    /// 窗口出现：建立连接（幂等）
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // 每次开窗重新计：首次握手前不喊「连接中断」
        hasConnectedOnce = false
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// 窗口关闭：停流。缓冲保留，下次开窗还能看到上次的内容
    func stop() {
        guard isRunning else { return }
        isRunning = false

        runTask?.cancel()
        runTask = nil

        let current = client
        client = nil
        Task { await current?.stopLogs() }

        isConnected = false
        setPaused(false)
    }

    // MARK: - 连接循环

    /// 一条连接跑到断就退避重连；内核没运行就等着（窗口开着允许内核稍后启动）
    private func run() async {
        defer {
            runTask = nil
            isConnected = false
        }

        var attempt = 0
        while !Task.isCancelled {
            guard kernel.phase == .running, let port = kernel.port, let secret = kernel.secret else {
                isConnected = false
                // 内核还没起：1s 一次轻量轮询，不做 WS 重试
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let client = ClashAPIClient(port: port, secret: secret)
            self.client = client

            let stream = await client.logs(level: Self.streamLevel)
            // 握手在 producer 里进行，这里先乐观置位：真失败会立刻抛错，不会挂着假在线
            isConnected = true
            hasConnectedOnce = true

            do {
                for try await line in stream {
                    guard !Task.isCancelled else { return }
                    attempt = 0
                    append(line, secret: secret)
                }
            } catch {
                // 握手失败 / 断流：统一走退避重连
            }

            guard !Task.isCancelled else { return }
            self.client = nil
            isConnected = false

            attempt += 1
            try? await Task.sleep(for: Self.backoff(attempt: attempt))
        }
    }

    /// 1s → 2s → 4s → 8s 封顶（`core-process` §5）
    private static func backoff(attempt: Int) -> Duration {
        .seconds(min(1 << min(max(attempt - 1, 0), 3), 8))
    }

    private func append(_ line: LogLine, secret: String?) {
        lines.append(
            LogLine(
                id: line.id,
                level: line.level,
                payload: LogRedactor.redact(line.payload, secret: secret),
                date: line.date
            )
        )
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }

    // MARK: - 交互

    func toggleLevel(_ level: LogLine.Level) {
        if levelFilter.contains(level) {
            levelFilter.remove(level)
        } else {
            levelFilter.insert(level)
        }
    }

    /// 暂停 / 继续：暂停时冻结当前缓冲作为显示源，继续时回到实时缓冲
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        if paused { pausedLines = lines }
        isPaused = paused
    }

    func clear() {
        lines.removeAll()
        pausedLines.removeAll()
    }

    // MARK: - 导出

    /// 导出「当前看到的」内容（尊重级别筛选与暂停冻结）；脱敏已在入缓冲时完成
    func exportText() -> String {
        let text = visibleLines.map { line in
            "\(Self.timeFormatter.string(from: line.date)) [\(line.level.rawValue)] \(line.payload)"
        }
        .joined(separator: "\n")
        return text.isEmpty ? "" : text + "\n"
    }

    /// 写进用户选的目录，返回落盘路径
    @discardableResult
    func export(to directory: URL) throws -> URL {
        let url = directory.appending(path: "clash-logs-\(Self.fileStampFormatter.string(from: .now)).txt")
        try exportText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    #if DEBUG
    /// 自检用（`CLASH_LOG_HARNESS`）：走与真实帧相同的入口，命令行即可验证
    /// 环形缓冲 / 级别筛选 / 暂停 / 导出 / 脱敏，不必点菜单栏
    func appendForSelfCheck(level: LogLine.Level, payload: String, secret: String?) {
        append(LogLine(level: level, payload: payload), secret: secret)
    }
    #endif
}

// MARK: - 脱敏

/// 日志脱敏（`core-process` §7）：本次运行的 API secret + URL 里的 token / key 参数一律打码。
///
/// 只做「确定是凭据」的替换，不猜；拿不到 secret 时（如内核未运行）仍会过滤 URL 参数。
@MainActor
enum LogRedactor {

    static func redact(_ text: String, secret: String?) -> String {
        var result = text
        if let secret, !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return redactCredentials(in: result)
    }

    /// `?token=xxx` / `&key=xxx` / `&access_token=xxx` … → `?token=***`
    static func redactCredentials(in text: String) -> String {
        guard let regex = credentialRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1***"
        )
    }

    private static let credentialRegex = try? NSRegularExpression(
        // 取 `=` 前一个非空白、非 `=` 字符作为前缀（`?` / `&` / 引号都行），
        // 避免把正文里出现的 `token:` 之类误伤；值一直取到分隔符 / 空白为止
        pattern: #"(?i)([?&"'\s](?:token|key|secret|access_token|password|passwd|uuid)=)[^&\s"'<>]+"#,
        options: []
    )
}
