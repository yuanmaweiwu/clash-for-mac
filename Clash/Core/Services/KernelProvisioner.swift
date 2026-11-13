import Foundation
import Observation
import OSLog

/// 当前机器对应的内核资产（`adr/0001` 补充：允许 x86_64）。
///
/// 上游按 `darwin-<arch>` 发布两份互不通用的二进制：`arm64` / `amd64`。
/// 校验值也必须按架构分开（`Resources/Kernel/SHA256-<arch>`），
/// 否则 Intel 机器会拿 arm64 的哈希去校验 amd64 的字节，永远失败。
enum KernelAsset {
    #if arch(x86_64)
    /// 上游资产名里的架构后缀（注意不是 `x86_64`）
    static let suffix = "amd64"
    /// 面向用户的架构名（与 `uname -m` 一致）
    static let archLabel = "x86_64"
    #else
    static let suffix = "arm64"
    static let archLabel = "arm64"
    #endif

    /// 包内校验文件名
    static var checksumFileName: String { "SHA256-\(suffix)" }

    /// 校验失败文案里必须点明「当前架构 + 校验的是哪份资产」
    static var checksumNote: String {
        "当前机器架构 \(archLabel)，校验的是 \(suffix) 资产"
    }
}

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
    /// 另一个下载任务迟迟不结束（等锁超时）
    case busy
    /// 等待期间任务被取消
    case cancelled
    /// 检查更新失败：GitHub API 不可达 / 返回的不是 release JSON
    case updateCheck(String)
    /// 升级下载到的二进制 `-v` 输出不含目标 tag（或根本跑不起来）
    case kernelVersionMismatch(String)

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
            "内核校验失败：\(KernelAsset.checksumNote)，内容与预期不一致，已删除，请重试"
        case .disk:
            "内核写入失败：磁盘空间不足或目录不可写，请检查后重试"
        case .decompressFailed:
            "内核解压失败，请重试（或更换下载源）"
        case .allSourcesUnreachable:
            "所有下载源均不可达，可在设置里换镜像后重试"
        case .busy:
            "另一个内核下载任务尚未结束，请稍后重试"
        case .cancelled:
            "内核下载已取消"
        case .updateCheck:
            "检查更新失败：GitHub 不可达，可换下载镜像后重试"
        case .kernelVersionMismatch:
            "更新失败：下载的内核版本不符或无法执行，已保留原内核"
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
        case .busy: "busy（等待其他下载任务超时）"
        case .cancelled: "cancelled（任务取消）"
        case .updateCheck(let detail): "updateCheck（\(detail)）"
        case .kernelVersionMismatch(let detail): "kernelVersionMismatch（\(detail)）"
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

    /// 单次下载的总时限：内核 5 分钟、geodata 2 分钟
    private static let lockWaitTimeout: Duration = .seconds(30)

    private static let logger = Logger(subsystem: "com.clash.app", category: "provisioner")

    private(set) var phase: Phase = .idle

    /// 已安装内核版本：`kernel/VERSION` 优先（升级后由 provisioner 重写），
    /// 内置包首次启动时回退到包内 `Resources/Kernel/VERSION`。`nil` = 未安装。
    private(set) var installedVersion: String?

    /// 最新版本缓存：10 分钟内重复点「检查更新」不再打 GitHub API
    @ObservationIgnored private var cachedLatest: (tag: String, fetchedAt: Date)?

    /// 自检用：本轮进程发起过的请求计数（证明「检查更新只打 API、不下载资产」）
    @ObservationIgnored private(set) var apiRequestCount = 0
    @ObservationIgnored private(set) var assetRequestCount = 0

    /// 检查更新总时限：设置页按钮转圈不该超过 10 秒
    private static let latestCheckTimeout: TimeInterval = 10
    private static let latestCacheTTL: TimeInterval = 600

    /// 当前唯一的下载任务；串行化的锁
    @ObservationIgnored private var activeTask: Task<Void, Error>?

    private init() {
        installedVersion = Self.localVersion()
    }

    // MARK: - 入口

    /// 确保内核可执行，返回二进制 URL。
    ///
    /// 已有可执行文件直接返回（不重复下载、不发任何网络请求）；下载失败抛 `KernelProvisionError`。
    ///
    /// 内置内核变体（`CLASH_BUNDLE_KERNEL=1` 构建）：包内已有 `Resources/Kernel/mihomo`，
    /// 校验后拷到用户目录直接使用，**不发起任何网络请求**（连 geodata 也不下载）。
    @discardableResult
    func ensureKernel() async throws -> URL {
        if Self.hasKernel() {
            phase = .ready
            Self.logger.notice("内核已存在，跳过下载 path=\(AppPaths.kernelBinaryURL.path, privacy: .public)")
            return AppPaths.kernelBinaryURL
        }

        let begin = ContinuousClock.now
        if let bundled = Self.bundledKernelURL() {
            Self.logger.notice(
                "ensureKernel begin（内置内核，不联网）path=\(bundled.path, privacy: .public)"
            )
            try await runExclusive {
                if Self.hasKernel() {
                    self.phase = .ready
                    return
                }
                try await Self.installBundledKernel(from: bundled)
            }
            refreshInstalledVersion()
            Self.logger.notice("ensureKernel end（内置）elapsed=\(ContinuousClock.now - begin)")
        } else {
            Self.logger.notice("ensureKernel begin（缺少内核）")
            try await runExclusive {
                if Self.hasKernel() {
                    self.phase = .ready
                    return
                }
                try await self.downloadKernel()
            }
            Self.logger.notice("ensureKernel end elapsed=\(ContinuousClock.now - begin)")
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
        // 内置内核变体随包带了 geodata：先拷出来，缺什么再联网（ADR-0001 补充）
        Self.installBundledGeodataIfPresent()

        let fileManager = FileManager.default
        let needsGeoIP = !fileManager.fileExists(atPath: AppPaths.geoIPDatabaseURL.path)
        let needsGeoSite = !fileManager.fileExists(atPath: AppPaths.geoSiteDatabaseURL.path)
        guard needsGeoIP || needsGeoSite else {
            Self.logger.notice("geodata 已存在，跳过下载")
            return
        }

        Self.logger.notice("ensureGeodata begin geoip=\(needsGeoIP) geosite=\(needsGeoSite)")
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
        Self.logger.notice("ensureGeodata end")
    }

    /// 启动流程超时 / 取消时调用：取消正在跑的下载，避免它长期占着锁
    func cancelInFlight() {
        guard let activeTask else { return }
        Self.logger.notice("取消进行中的内核下载任务")
        activeTask.cancel()
    }

    /// 自检 / 排障：把状态复位成 idle（不清文件）
    func resetPhase() {
        guard !phase.isActive else { return }
        phase = .idle
    }

    // MARK: - 版本与升级（设置页）

    /// 进入设置页 / 升级完成后刷新一次；只读本地文件，**不联网**
    func refreshInstalledVersion() {
        installedVersion = Self.localVersion()
    }

    /// 本地版本：`kernel/VERSION` 优先（内置包拷出内核时 / 升级后都会写这份），
    /// 其次回退到包内 `Resources/Kernel/VERSION`（内置包刚装好、内核还没用过的场景）
    static func localVersion() -> String? {
        if let installed = readVersion(at: AppPaths.kernelVersionURL) { return installed }
        return bundledVersion()
    }

    /// 检查最新版本：**只发 GitHub API 请求，不下载任何资产、不碰磁盘**。
    ///
    /// 顺序是硬约束（避免「先下后判」）：
    /// 1. 调用方先看 `installedVersion`：没内核 → 直接走下载；已是最新 → 到此为止
    /// 2. 这里只回答「上游最新 tag 是什么」（10 分钟缓存，重复点不重复打 API）
    /// 3. `latest != installed` 时才由调用方发起资产下载（`update(to:)`）
    func latestVersion() async throws -> String {
        if let cached = cachedLatest, Date().timeIntervalSince(cached.fetchedAt) < Self.latestCacheTTL {
            Self.logger.notice("检查更新：命中 10 分钟缓存 tag=\(cached.tag, privacy: .public)（未发请求）")
            return cached.tag
        }

        let sources = KernelDownloadSelection.resolve().sources
        let deadline = Date().addingTimeInterval(Self.latestCheckTimeout)
        var lastDetail = "没有可用的下载源"

        for prefix in sources {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.5 else { break }
            guard let url = Self.releaseAPIURL(prefix: prefix) else {
                lastDetail = "地址无效（prefix=\(prefix)）"
                continue
            }

            apiRequestCount += 1
            Self.logger.notice("检查更新：GET \(url.absoluteString, privacy: .public)（仅 API，不下载资产）")
            do {
                let tag = try await Self.fetchLatestTag(url: url, timeout: min(6, remaining))
                Self.logger.notice("检查更新：最新 tag=\(tag, privacy: .public)")
                cachedLatest = (tag, Date())
                return tag
            } catch {
                lastDetail = String(describing: error)
                Self.logger.notice(
                    "检查更新失败 source=\(KernelDownloadMirrors.displayName(for: prefix), privacy: .public)：\(lastDetail, privacy: .public)"
                )
            }
        }
        throw KernelProvisionError.updateCheck(lastDetail)
    }

    /// 升级到指定 tag；成功返回装上的版本。
    ///
    /// **调用方负责停 / 起内核**（`PanelPreviewModel` 走 `KernelService` 的重启路径），
    /// 这里只换文件 + 写 `kernel/VERSION`，绝不碰进程。
    ///
    /// 校验强度：上游 release 没有 checksums 资产 → 升级只有 HTTPS 传输 + `mihomo -v`
    /// 语义自检；密码学级保证只存在于固定版本构建（`Resources/Kernel/SHA256-<arch>`）。
    @discardableResult
    func update(to tag: String) async throws -> String {
        let expected = Self.bundledVersion() == tag ? Self.bundledChecksum() : nil
        Self.logger.notice(
            "开始更新内核 → \(tag, privacy: .public)（校验：\(expected == nil ? "HTTPS + mihomo -v 自检" : "包内 SHA256", privacy: .public)）"
        )
        do {
            try await runExclusive {
                try await self.installKernel(
                    tag: tag,
                    expectedChecksum: expected,
                    requiresVersionSelfCheck: true
                )
            }
        } catch {
            let mapped = Self.mapDownloadError(error)
            Self.logger.error("内核更新失败：\(mapped.logDescription, privacy: .public)")
            // 旧内核还在：相位回 ready，别让面板停在「更新失败」的失败态
            phase = Self.hasKernel() ? .ready : .failed(mapped)
            throw mapped
        }
        refreshInstalledVersion()
        phase = .ready
        return tag
    }

    // MARK: - 串行化

    /// 同一时刻只跑一个下载任务。
    ///
    /// 后到者**轮询等待**（不用 `await task.value` 无限等）：等锁最多 30 秒，
    /// 超时直接抛 `.busy`。这样即使前一个任务卡死 / 被取消，也不会有调用方永久挂起。
    private func runExclusive(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let deadline = ContinuousClock.now + Self.lockWaitTimeout
        while activeTask != nil {
            if ContinuousClock.now >= deadline {
                Self.logger.error("等待其他下载任务超过 \(Int(Self.lockWaitTimeout.components.seconds)) 秒，放弃")
                throw fail(.busy)
            }
            if Task.isCancelled { throw KernelProvisionError.cancelled }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let task = Task { @MainActor in
            try await operation()
        }
        activeTask = task
        defer { activeTask = nil }
        do {
            try await task.value
        } catch {
            // 任务失败 / 取消也必须清锁；`defer` 保证，这里只补日志
            Self.logger.notice("下载任务结束（失败或取消）：\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - 内核

    /// 首次下载：版本与校验值都来自包内元数据（ADR-0012）
    private func downloadKernel() async throws {
        guard let tag = Self.bundledVersion() else {
            throw fail(.metadataMissing("Resources/Kernel/VERSION"))
        }
        guard let expected = Self.bundledChecksum() else {
            throw fail(.metadataMissing("Resources/Kernel/\(KernelAsset.checksumFileName)"))
        }
        try await installKernel(tag: tag, expectedChecksum: expected, requiresVersionSelfCheck: false)
    }

    /// 下载指定版本并原子落地。
    ///
    /// - `expectedChecksum != nil`（固定版本：包内元数据有这一版的哈希）→ 走 SHA256，密码学级
    /// - `expectedChecksum == nil`（升级到任意 tag）→ 上游 release **没有 checksums 资产**，
    ///   只能靠 HTTPS + `mihomo -v` 输出含目标 tag 做语义自检；这不是密码学级校验
    ///
    /// 失败路径绝不碰 `kernel/mihomo`：新二进制只在全部校验通过后才 rename 过去。
    private func installKernel(
        tag: String,
        expectedChecksum: String?,
        requiresVersionSelfCheck: Bool
    ) async throws {
        let selection = KernelDownloadSelection.resolve()
        let sources = selection.sources
        Self.logger.notice(
            "开始下载内核 tag=\(tag, privacy: .public) arch=\(KernelAsset.suffix, privacy: .public) mode=\(selection.mode.rawValue, privacy: .public) sources=\(sources.count)"
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
                "尝试下载源 \(index + 1)/\(sources.count)：\(sourceName, privacy: .public) url=\(url.absoluteString, privacy: .public)"
            )
            countAssetRequest()
            phase = .downloading(received: 0, total: nil)

            do {
                if let override = Self.debugAssetOverride {
                    // 破坏验证：本地假资产替代下载，走完校验链路才落盘
                    Self.logger.notice("DEBUG 覆盖资产：\(override.path, privacy: .public)")
                    try? fileManager.removeItem(at: gzURL)
                    try fileManager.copyItem(at: override, to: gzURL)
                } else {
                    // 22MB 资产在慢网（实测 ~80KB/s）要 5 分钟以上：总时限给 15 分钟，
                    // 单次空闲超时仍由 `KernelDownloadMirrors.attemptTimeout`（10s）兜底
                    try await Self.download(url: url, to: gzURL, resourceTimeout: 900) { [weak self] received, total in
                        guard let self else { return }
                        Task { @MainActor in
                            self.phase = .downloading(received: received, total: total > 0 ? total : nil)
                        }
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
                if let expectedChecksum, actual != expectedChecksum {
                    throw KernelProvisionError.checksumMismatch(expected: expectedChecksum, actual: actual)
                }

                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedURL.path)

                if requiresVersionSelfCheck {
                    let output = await Self.toolOutput(
                        executable: stagedURL,
                        arguments: ["-v"],
                        timeout: 10
                    )
                    guard Self.versionOutput(output, matches: tag) else {
                        throw KernelProvisionError.kernelVersionMismatch(
                            "期望 \(tag)，实际输出：\(Self.clipped(output))"
                        )
                    }
                }

                // 「先删再 rename」：最终路径上永远不会出现半截文件
                if fileManager.fileExists(atPath: AppPaths.kernelBinaryURL.path) {
                    try fileManager.removeItem(at: AppPaths.kernelBinaryURL)
                }
                try fileManager.moveItem(at: stagedURL, to: AppPaths.kernelBinaryURL)
                try? Data("\(tag)\n".utf8).write(to: AppPaths.kernelVersionURL, options: .atomic)
                installedVersion = tag

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

        // 校验类失败（哈希不符 / 版本不符 / 解压失败）要原样上抛：
        // 归成「所有源不可达」会让用户以为换网络就能解决。
        switch lastError {
        case .checksumMismatch, .kernelVersionMismatch, .decompressFailed:
            throw fail(lastError)
        default:
            throw fail(.allSourcesUnreachable)
        }
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
                try await Self.download(url: url, to: tmpURL, resourceTimeout: 120) { [weak self] received, total in
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

    /// 每发起一次资产下载就 +1（自检用：检查更新应保持 0）
    private func countAssetRequest() {
        assetRequestCount += 1
    }

    // MARK: - 内置内核（CLASH_BUNDLE_KERNEL=1）

    /// 包内自带的 `Contents/Resources/Kernel/mihomo`；不存在 = 下载包（不额外用标志位文件区分）
    private static func bundledKernelURL() -> URL? {
        guard let url = bundledResource("mihomo"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 校验包内内核后拷到用户目录（0755，`tmp` → rename，绝不联网）。
    ///
    /// 校验不过**不**回退到下载：包里那份被替换 / 拷坏属于安装包本身有问题，
    /// 静默改走网络只会把「包坏了」伪装成「网络慢」。
    private static func installBundledKernel(from source: URL) async throws {
        guard let expected = bundledChecksum() else {
            throw KernelProvisionError.metadataMissing("Resources/Kernel/\(KernelAsset.checksumFileName)")
        }
        let fileManager = FileManager.default
        let staged = AppPaths.kernelDirectory.appending(path: ".mihomo-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staged) }

        do {
            try fileManager.copyItem(at: source, to: staged)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        } catch {
            throw KernelProvisionError.disk("无法从安装包复制内核：\(error.localizedDescription)")
        }

        let actual: String
        do {
            actual = try await sha256(of: staged)
        } catch {
            throw KernelProvisionError.disk("无法计算内置内核校验值")
        }
        guard actual == expected else {
            throw KernelProvisionError.checksumMismatch(expected: expected, actual: actual)
        }

        if fileManager.fileExists(atPath: AppPaths.kernelBinaryURL.path) {
            try fileManager.removeItem(at: AppPaths.kernelBinaryURL)
        }
        try fileManager.moveItem(at: staged, to: AppPaths.kernelBinaryURL)
        // 版本一起落地：之后「当前版本」只看 kernel/VERSION，与下载包走同一条路径
        if let version = bundledVersion() {
            try? Data("\(version)\n".utf8).write(to: AppPaths.kernelVersionURL, options: .atomic)
        }
        Self.logger.notice("内置内核已拷出（未联网）sha256=\(actual, privacy: .public)")
    }

    /// 内置变体随包带了 geodata：拷出来，避免首次启动为它联网
    private static func installBundledGeodataIfPresent() {
        let fileManager = FileManager.default
        let pairs = [
            ("geoip.metadb", AppPaths.geoIPDatabaseURL),
            ("geosite.dat", AppPaths.geoSiteDatabaseURL)
        ]
        for (name, destination) in pairs {
            guard !fileManager.fileExists(atPath: destination.path),
                  let source = bundledResource(name),
                  fileManager.fileExists(atPath: source.path) else { continue }
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                Self.logger.warning("内置 \(name, privacy: .public) 拷贝失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 地址与元数据

    /// `<镜像前缀> + 原始 GitHub URL`（原样拼接，不做改写；空前缀 = 直连）
    private static func remoteURL(path: String, prefix: String) -> URL? {
        let original = "https://github.com/" + path
        return URL(string: prefix.isEmpty ? original : prefix + original)
    }

    /// GitHub API 也要走镜像链：预置镜像不一定转发 API，失败就换下一个源（首个源是直连）
    private static func releaseAPIURL(prefix: String) -> URL? {
        let original = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        return URL(string: prefix.isEmpty ? original : prefix + original)
    }

    private static func kernelURL(tag: String, prefix: String) -> URL? {
        remoteURL(
            path: "MetaCubeX/mihomo/releases/download/\(tag)/mihomo-darwin-\(KernelAsset.suffix)-\(tag).gz",
            prefix: prefix
        )
    }

    private static func geodataURL(name: String, prefix: String) -> URL? {
        remoteURL(path: "MetaCubeX/meta-rules-dat/releases/download/latest/\(name)", prefix: prefix)
    }

    /// 包内 `Contents/Resources/Kernel/VERSION`（ADR-0012：唯一版本依据）
    private static func bundledVersion() -> String? {
        guard let url = bundledResource("VERSION") else { return nil }
        return readVersion(at: url)
    }

    private static func readVersion(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// 包内 `Contents/Resources/Kernel/SHA256-<arch>`：`<hash>  mihomo`
    ///
    /// 按架构分开是硬要求：arm64 与 amd64 是两份不同的二进制，哈希互不通用。
    private static func bundledChecksum() -> String? {
        guard let url = bundledResource(KernelAsset.checksumFileName),
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

    /// DEBUG 自检钩子：用本地文件替代资产下载（破坏验证用；Release 恒为 nil）
    private static var debugAssetOverride: URL? {
        #if DEBUG
        guard let path = getenv("CLASH_KERNEL_ASSET_OVERRIDE") else { return nil }
        let value = String(cString: path)
        return value.isEmpty ? nil : URL(fileURLWithPath: value)
        #else
        return nil
        #endif
    }


    // MARK: - 下载（URLSession + 进度）

    /// 问上游「最新 release 是哪个 tag」：**只读 API，不下载资产**
    private static func fetchLatestTag(url: URL, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KernelProvisionError.updateCheck("非 HTTP 响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw KernelProvisionError.updateCheck("HTTP \(http.statusCode)")
        }

        struct Release: Decodable {
            let tag: String
            enum CodingKeys: String, CodingKey { case tag = "tag_name" }
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.tag.hasPrefix("v"), release.tag.count > 1 else {
            throw KernelProvisionError.updateCheck("返回内容不是 release JSON（镜像可能回了 HTML）")
        }
        return release.tag
    }

    private static func download(
        url: URL,
        to destination: URL,
        resourceTimeout: TimeInterval,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = KernelDownloadDelegate(destination: destination, onProgress: onProgress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = KernelDownloadMirrors.attemptTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.attach(continuation)
                let request = URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: KernelDownloadMirrors.attemptTimeout
                )
                let task = session.downloadTask(with: request)
                delegate.attach(task: task)
                task.resume()
            }
        } onCancel: {
            // 启动流程超时 / 取消：必须把 URLSession 任务也取消，否则 continuation 永不 resume
            delegate.cancel()
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

    /// 跑一次子进程，合并收集 stdout + stderr（`mihomo -v` 自检用）
    ///
    /// 有硬超时：坏二进制 / 假文件可能挂住，不能让设置页的「更新」永远转圈。
    private static func toolOutput(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return "无法执行：\(error.localizedDescription)"
            }

            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// `mihomo -v` 输出必须含目标 tag：上游没有 checksums 资产时的语义自检
    private static func versionOutput(_ output: String, matches tag: String) -> Bool {
        guard !tag.isEmpty else { return false }
        return output.lowercased().contains(tag.lowercased())
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
    private var task: URLSessionTask?
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

    func attach(task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// 取消 URLSession 任务 → `didCompleteWithError` 会把 continuation resume 掉
    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
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
