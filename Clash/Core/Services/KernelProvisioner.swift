import Foundation
import Observation
import OSLog

/// 内核下载 / 校验失败的原因（`adr/0012`）。
///
/// 分类必须能对上用户能采取的动作：网络不通（换网络 / 填镜像）、校验失败（重试）、
/// 磁盘写不进去（清空间 / 查权限）。**不允许**静默回退到「那就没有内核」。
enum KernelProvisionError: Error, Equatable, Sendable {
    /// 包内缺 `Resources/Kernel/VERSION` 或 `SHA256`（构建期漏拷）
    case metadataMissing(String)
    /// 传输层失败：断网 / DNS / 超时 / 镜像不可达；参数只进日志
    case network(String)
    /// HTTP 非 2xx（镜像返回 404 / 403 等）
    case httpStatus(Int)
    /// 解压后的 sha256 与 committed 的 `SHA256` 不一致
    case checksumMismatch(expected: String, actual: String)
    /// 磁盘写入 / 移动失败
    case disk(String)
    /// `gunzip` 失败
    case decompressFailed(String)
    /// 自动模式下所有源都不可达（有一个成功就不会走到这里）
    case allSourcesUnreachable
    /// 等待期间任务被取消
    case cancelled

    /// 面向用户的一句话（banner / 提示）
    var userMessage: String {
        switch self {
        case .metadataMissing:
            "安装包缺少内核版本信息，请重新安装应用"
        case .network:
            "内核下载失败：网络不可达，请检查网络，或在设置里填写下载镜像后重试"
        case .httpStatus(let code):
            "内核下载失败：服务器返回 \(code)，可稍后重试或更换下载镜像"
        case .checksumMismatch:
            "内核校验失败：下载内容与预期不一致，已删除，请重试"
        case .disk:
            "内核写入失败：磁盘空间不足或目录不可写，请检查后重试"
        case .decompressFailed:
            "内核解压失败，请重试（或更换下载源）"
        case .allSourcesUnreachable:
            "所有下载源均不可达，可在设置里换镜像后重试"
        case .cancelled:
            "内核下载已取消"
        }
    }

    /// 只进日志的细节（不含订阅 / secret）
    var logDescription: String {
        switch self {
        case .metadataMissing(let name): "metadataMissing（缺 \(name)）"
        case .network(let detail): "network（\(detail)）"
        case .httpStatus(let code): "httpStatus（\(code)）"
        case .checksumMismatch(let expected, let actual):
            "checksumMismatch（expected=\(expected) actual=\(actual)）"
        case .disk(let detail): "disk（\(detail)）"
        case .decompressFailed(let detail): "decompressFailed（\(detail)）"
        case .allSourcesUnreachable: "allSourcesUnreachable（所有下载源失败）"
        case .cancelled: "cancelled（任务取消）"
        }
    }
}

/// 下载 + 校验内核与 geodata（ADR-0012）。
///
/// 约定：
/// - 包内只有 `Resources/Kernel/VERSION` 与 `SHA256`；二进制和地理数据在首次需要时下载到
///   `AppPaths.kernelDirectory`
/// - 落地一律「`.tmp` → rename」，失败路径删干净临时文件，**不留半截内核**
/// - 串行化：同一时刻只允许一个下载任务；后来的调用等前一个结束，再按需重做自己的检查
/// - 进度以 `phase` 暴露（10Hz 足够），UI 通过 `KernelService` / `PanelPreviewModel` 读取
@MainActor
@Observable
final class KernelProvisioner {

    /// 供 `KernelService` / `ProfileValidator` / `TunService` 共享的实例（并发保护也在这里）
    static let shared = KernelProvisioner()

    enum Phase: Equatable, Sendable {
        case idle
        /// 读 VERSION / SHA256、拼 URL
        case checking
        case downloading(received: Int64, total: Int64?)
        /// gunzip 后算 sha256
        case verifying
        case ready
        case failed(KernelProvisionError)

        var isActive: Bool {
            switch self {
            case .checking, .downloading, .verifying: true
            case .idle, .ready, .failed: false
            }
        }

        /// 0...1；总长度未知时 nil（UI 用不确定进度条）
        var progress: Double? {
            guard case .downloading(let received, let total) = self,
                  let total, total > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(total)))
        }

        /// 状态行文案；`nil` = 不需要展示
        var statusText: String? {
            switch self {
            case .idle, .ready:
                nil
            case .checking:
                "正在准备内核…"
            case .downloading(let received, let total):
                if let total, total > 0 {
                    "正在下载内核组件… \(Int(progress.map { $0 * 100 } ?? 0))%"
                } else {
                    "正在下载内核组件… \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))"
                }
            case .verifying:
                "正在校验内核…"
            case .failed(let error):
                error.userMessage
            }
        }
    }

    private static let logger = Logger(subsystem: "com.clash.app", category: "provisioner")

    private(set) var phase: Phase = .idle

    /// 当前唯一的下载任务；串行化的锁
    @ObservationIgnored private var activeTask: Task<Void, Error>?

    private init() {}

    // MARK: - 入口

    /// 确保内核可执行，返回二进制 URL。
    ///
    /// 已有可执行文件直接返回（不重复下载）；下载失败抛 `KernelProvisionError`。
    @discardableResult
    func ensureKernel() async throws -> URL {
        if Self.hasKernel() {
            phase = .ready
            return AppPaths.kernelBinaryURL
        }

        try await runExclusive {
            if Self.hasKernel() {
                self.phase = .ready
                return
            }
            try await self.downloadKernel()
        }

        guard Self.hasKernel() else {
            throw KernelProvisionError.disk("内核落地后不可执行：\(AppPaths.kernelBinaryURL.path)")
        }
        phase = .ready
        return AppPaths.kernelBinaryURL
    }

    /// 确保 geodata 存在（调用方判断「这份订阅是否真的需要」）。
    ///
    /// `geoip.metadb` 必需，失败即抛错；`geosite.dat` 尽力而为，失败只记日志。
    func ensureGeodata() async throws {
        let fileManager = FileManager.default
        let needsGeoIP = !fileManager.fileExists(atPath: AppPaths.geoIPDatabaseURL.path)
        let needsGeoSite = !fileManager.fileExists(atPath: AppPaths.geoSiteDatabaseURL.path)
        guard needsGeoIP || needsGeoSite else { return }

        try await runExclusive {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: AppPaths.geoIPDatabaseURL.path) {
                try await self.downloadGeodataFile(name: "geoip.metadb", to: AppPaths.geoIPDatabaseURL, required: true)
            }
            if !fileManager.fileExists(atPath: AppPaths.geoSiteDatabaseURL.path) {
                do {
                    try await self.downloadGeodataFile(
                        name: "geosite.dat",
                        to: AppPaths.geoSiteDatabaseURL,
                        required: false
                    )
                } catch {
                    // 尽力而为：`GEOSITE,` 规则会退化，但内核仍可启动
                    Self.logger.warning("geosite.dat 下载失败，继续启动：\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// 自检 / 排障：把状态复位成 idle（不清文件）
    func resetPhase() {
        guard !phase.isActive else { return }
        phase = .idle
    }

    // MARK: - 串行化

    /// 同一时刻只跑一个下载任务；后到者先等前一个结束，再重新做自己的存在性检查
    private func runExclusive(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        while let running = activeTask {
            _ = try? await running.value
        }
        let task = Task { @MainActor in
            try await operation()
        }
        activeTask = task
        defer { activeTask = nil }
        try await task.value
    }

    // MARK: - 内核

    private func downloadKernel() async throws {
        guard let tag = Self.bundledVersion() else {
            throw fail(.metadataMissing("Resources/Kernel/VERSION"))
        }
        guard let expected = Self.bundledChecksum() else {
            throw fail(.metadataMissing("Resources/Kernel/SHA256"))
        }

        let selection = KernelDownloadSelection.resolve()
        let sources = selection.sources
        Self.logger.notice(
            "开始下载内核 tag=\(tag, privacy: .public) mode=\(selection.mode.rawValue, privacy: .public) sources=\(sources.count)"
        )

        let fileManager = FileManager.default
        let gzURL = AppPaths.kernelDirectory.appending(path: ".mihomo-\(UUID().uuidString).gz")
        let stagedURL = AppPaths.kernelDirectory.appending(path: ".mihomo-\(UUID().uuidString).tmp")
        defer {
            try? fileManager.removeItem(at: gzURL)
            try? fileManager.removeItem(at: stagedURL)
        }

        var lastError: KernelProvisionError = .network("没有可用的下载源")
        for (index, prefix) in sources.enumerated() {
            let sourceName = KernelDownloadMirrors.displayName(for: prefix)
            guard let url = Self.kernelURL(tag: tag, prefix: prefix) else {
                lastError = .network("下载地址无效（prefix=\(prefix)）")
                continue
            }

            try? fileManager.removeItem(at: gzURL)
            try? fileManager.removeItem(at: stagedURL)
            Self.logger.notice(
                "尝试下载源 \(index + 1)/\(sources.count)：\(sourceName, privacy: .public)"
            )
            phase = .downloading(received: 0, total: nil)

            do {
                try await Self.download(url: url, to: gzURL) { [weak self] received, total in
                    guard let self else { return }
                    Task { @MainActor in
                        self.phase = .downloading(received: received, total: total > 0 ? total : nil)
                    }
                }

                phase = .verifying
                let unzip = await Self.gunzip(gzURL, to: stagedURL)
                guard unzip.status == 0 else {
                    throw KernelProvisionError.decompressFailed(Self.clipped(unzip.output))
                }

                let actual: String
                do {
                    actual = try await Self.sha256(of: stagedURL)
                } catch {
                    throw KernelProvisionError.disk("无法计算内核校验值")
                }
                // 每个源都必须过这一关：镜像只能转发字节，无法替换内核
                guard actual == expected else {
                    throw KernelProvisionError.checksumMismatch(expected: expected, actual: actual)
                }

                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedURL.path)
                // 「先删再 rename」：最终路径上永远不会出现半截文件
                if fileManager.fileExists(atPath: AppPaths.kernelBinaryURL.path) {
                    try fileManager.removeItem(at: AppPaths.kernelBinaryURL)
                }
                try fileManager.moveItem(at: stagedURL, to: AppPaths.kernelBinaryURL)

                Self.logger.notice(
                    "内核下载成功 source=\(sourceName, privacy: .public) tag=\(tag, privacy: .public) sha256=\(actual, privacy: .public)"
                )
                return
            } catch {
                let mapped = Self.mapDownloadError(error)
                lastError = mapped
                Self.logger.notice(
                    "下载源 \(sourceName, privacy: .public) 失败：\(mapped.logDescription, privacy: .public)"
                )
                // 磁盘写不进去换源也没用：立即失败，别让用户等三轮超时
                if case .disk = mapped { throw fail(mapped) }
            }
        }

        if case .checksumMismatch = lastError {
            throw fail(lastError)
        }
        throw fail(.allSourcesUnreachable)
    }

    // MARK: - geodata

    private func downloadGeodataFile(name: String, to destination: URL, required: Bool) async throws {
        let sources = KernelDownloadSelection.resolve().sources
        let fileManager = FileManager.default
        let tmpURL = AppPaths.kernelDirectory.appending(path: ".\(name)-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: tmpURL) }

        var lastError: KernelProvisionError = .network("没有可用的下载源")
        for prefix in sources {
            let sourceName = KernelDownloadMirrors.displayName(for: prefix)
            guard let url = Self.geodataURL(name: name, prefix: prefix) else {
                lastError = .network("geodata 地址无效（\(name)）")
                continue
            }

            try? fileManager.removeItem(at: tmpURL)
            // geodata 文件不大（metadb 约 8MB）：沿用同一个 phase，UI 不必区分
            phase = .downloading(received: 0, total: nil)
            do {
                try await Self.download(url: url, to: tmpURL) { [weak self] received, total in
                    guard let self else { return }
                    Task { @MainActor in
                        self.phase = .downloading(received: received, total: total > 0 ? total : nil)
                    }
                }

                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: tmpURL, to: destination)
                Self.logger.notice(
                    "geodata 下载成功 \(name, privacy: .public) source=\(sourceName, privacy: .public)"
                )
                return
            } catch {
                lastError = Self.mapDownloadError(error)
                Self.logger.notice(
                    "geodata \(name, privacy: .public) 源 \(sourceName, privacy: .public) 失败：\(lastError.logDescription, privacy: .public)"
                )
            }
        }

        if required {
            if case .checksumMismatch = lastError {
                throw fail(lastError)
            }
            throw fail(.allSourcesUnreachable)
        }
        Self.logger.warning("\(name) 所有源均失败，继续启动：\(lastError.logDescription, privacy: .public)")
    }

    // MARK: - 状态

    @discardableResult
    private func fail(_ error: KernelProvisionError) -> KernelProvisionError {
        phase = .failed(error)
        Self.logger.error("内核准备失败：\(error.logDescription, privacy: .public)")
        return error
    }

    private static func hasKernel() -> Bool {
        FileManager.default.isExecutableFile(atPath: AppPaths.kernelBinaryURL.path)
    }

    // MARK: - 地址与元数据

    /// `<镜像前缀> + 原始 GitHub URL`（原样拼接，不做改写；空前缀 = 直连）
    private static func remoteURL(path: String, prefix: String) -> URL? {
        let original = "https://github.com/" + path
        return URL(string: prefix.isEmpty ? original : prefix + original)
    }

    private static func kernelURL(tag: String, prefix: String) -> URL? {
        remoteURL(path: "MetaCubeX/mihomo/releases/download/\(tag)/mihomo-darwin-arm64-\(tag).gz", prefix: prefix)
    }

    private static func geodataURL(name: String, prefix: String) -> URL? {
        remoteURL(path: "MetaCubeX/meta-rules-dat/releases/download/latest/\(name)", prefix: prefix)
    }

    /// 包内 `Contents/Resources/Kernel/VERSION`（ADR-0012：唯一版本依据）
    private static func bundledVersion() -> String? {
        guard let url = bundledResource("VERSION"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// 包内 `Contents/Resources/Kernel/SHA256`：`<hash>  mihomo`
    private static func bundledChecksum() -> String? {
        guard let url = bundledResource("SHA256"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let hash = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let value = String(hash).lowercased()
        return value.count == 64 ? value : nil
    }

    private static func bundledResource(_ name: String) -> URL? {
        for subdirectory in ["Resources/Kernel", "Kernel"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }

    // MARK: - 错误归类

    private static func mapDownloadError(_ error: Error) -> KernelProvisionError {
        if let provision = error as? KernelProvisionError { return provision }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed,
                 .serverCertificateUntrusted, .zeroByteResource:
                return .network("\(urlError.code.rawValue) \(urlError.localizedDescription)")
            default:
                return .network("\(urlError.code.rawValue) \(urlError.localizedDescription)")
            }
        }
        return .network(error.localizedDescription)
    }

    private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: "\n").last else { return "未知错误" }
        let line = String(last)
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    // MARK: - 下载（URLSession + 进度）

    private static func download(
        url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = KernelDownloadDelegate(destination: destination, onProgress: onProgress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = KernelDownloadMirrors.attemptTimeout
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.attach(continuation)
            let request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: KernelDownloadMirrors.attemptTimeout
            )
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    // MARK: - 解压与校验

    private struct ProcessOutcome: Sendable {
        let status: Int32
        let output: String
    }

    /// 系统 `gunzip -c` 解到目标文件（不引入 zlib 依赖）
    private static func gunzip(_ source: URL, to destination: URL) async -> ProcessOutcome {
        await Task.detached(priority: .userInitiated) { () -> ProcessOutcome in
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: destination) else {
                return ProcessOutcome(status: -1, output: "无法写入临时文件")
            }
            defer { try? handle.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-c", source.path]
            let errors = Pipe()
            process.standardOutput = handle
            process.standardError = errors

            do {
                try process.run()
            } catch {
                return ProcessOutcome(status: -1, output: error.localizedDescription)
            }

            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessOutcome(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }.value
    }

    private static func sha256(of url: URL) async throws -> String {
        let outcome = await Task.detached(priority: .userInitiated) { () -> ProcessOutcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            process.arguments = ["-a", "256", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return ProcessOutcome(status: -1, output: error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessOutcome(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }.value

        guard outcome.status == 0,
              let hash = outcome.output.split(whereSeparator: \.isWhitespace).first else {
            throw KernelProvisionError.disk("shasum 失败：\(outcome.status)")
        }
        return String(hash).lowercased()
    }
}

// MARK: - 下载委托

/// `URLSessionDownloadDelegate` 的薄封装：把文件挪到目标位置 + 10Hz 进度 + 一次性 resume。
private final class KernelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastProgressAt = Date.distantPast

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastProgressAt) >= 0.1
        if shouldEmit { lastProgressAt = now }
        lock.unlock()

        guard shouldEmit else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            record(KernelProvisionError.httpStatus(http.statusCode))
            return
        }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            record(KernelProvisionError.disk(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        lock.unlock()

        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else if let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume()
        }
    }

    private func record(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }
}
