import Foundation
import OSLog

/// 系统代理开关与安全还原（`.agents/skills/system-proxy`，`docs/01-ARCHITECTURE.md` §6）。
///
/// 最高优先级不是「能开」，而是「一定能还原」。两条不变式：
/// 1. **快照先于写入**：没有把快照原子落盘，绝不动系统代理
/// 2. **快照存在 ⟺ 我们改过系统代理且尚未还原**：任何失败都在有快照的前提下回滚，
///    回滚失败则保留快照，交给下次启动的 `restoreIfNeeded()` 兜底
///
/// 实测（macOS 15.7 / 管理员账号）：本进程直接跑 `networksetup` 即可写代理，
/// 不需要 root、不需要 helper（`adr/0008`：helper 只为 TUN 存在）。
/// 非管理员 / MDM 锁定时命令会报权限错误 → `notAdmin`，给明确提示，不静默。
@MainActor
@Observable
final class SystemProxyService {

    // MARK: - 对 UI 暴露的状态

    /// 我们是否接管了系统代理（= 快照存在且未还原）
    private(set) var isEnabled = false
    private(set) var lastError: SystemProxyError?
    /// 开 / 关进行中：磁贴禁用点击
    private(set) var isTransitioning = false

    /// 快照路径（自检时指向临时目录，生产恒为 `AppPaths.systemProxySnapshotURL`）
    let snapshotURL: URL

    init(snapshotURL: URL = AppPaths.systemProxySnapshotURL) {
        self.snapshotURL = snapshotURL
        isEnabled = FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    var hasSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    // MARK: - 采集与快照

    /// 枚举需要处理的网络服务（跳过已禁用服务）
    func services() async throws -> [String] {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Networksetup.listServices()
            }.value
        } catch {
            throw report(error)
        }
    }

    /// 采集全部服务并原子写快照（0600）。**这是开启前唯一允许的落盘动作。**
    ///
    /// 只做「采集 + 落盘」，不改系统代理；已有未还原的快照时拒绝覆盖（先 `disable()`）。
    @discardableResult
    func snapshot(kernelPort: Int = RuntimeConfigBuilder.defaultMixedPort) async throws -> SystemProxySnapshot {
        guard !hasSnapshot else {
            throw report(SystemProxyError.snapshotWriteFailed(detail: "已有未还原的快照，先调用 disable()"))
        }
        let url = snapshotURL
        do {
            return try await Task.detached(priority: .userInitiated) {
                let snapshot = try Networksetup.capture(kernelPort: kernelPort)
                try Networksetup.save(snapshot, to: url)
                return snapshot
            }.value
        } catch {
            throw report(error)
        }
    }

    /// 读取某个服务当前的代理状态（排障 / 自检用）
    func currentState(of name: String) async throws -> ServiceProxyState {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Networksetup.readState(name)
            }.value
        } catch {
            throw report(error)
        }
    }

    // MARK: - 开启

    /// 快照 → 逐服务设置 → 读回校验；任一环节失败都按快照全量还原后抛错。
    func enable(port: Int) async throws {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        lastError = nil

        // 已有快照 = 上一轮没还原干净：先把用户原值还原掉，
        // 否则会把「我们写进去的 127.0.0.1:port」当成用户原值再快照一次。
        if hasSnapshot {
            do {
                // 不走 `disable()`：它在 `isTransitioning` 时会直接返回，这里必须真还原
                try await performDisable()
            } catch {
                let mapped = Self.mapped(error)
                lastError = mapped
                throw mapped
            }
        }

        let url = snapshotURL
        #if DEBUG
        let failVerification = debugFailVerification
        #else
        let failVerification = false
        #endif

        do {
            try await Task.detached(priority: .userInitiated) {
                try Networksetup.activate(
                    port: port,
                    snapshotURL: url,
                    failVerification: failVerification
                )
            }.value
            isEnabled = true
            lastError = nil
            systemProxyLogger.notice("系统代理已开启 port=\(port, privacy: .public)")
        } catch {
            let mapped = Self.mapped(error)
            lastError = mapped
            systemProxyLogger.error("开启系统代理失败：\(mapped.logDescription, privacy: .public)")
            // `activate` 内部已回滚；这里只兜「回滚本身也失败」的残留，绝不留下半开状态
            forceRestoreIfSnapshotExists()
            throw mapped
        }
    }

    // MARK: - 关闭 / 还原

    /// 读快照 → 逐项还原 → 读回校验 → 全成功才删快照。
    func disable() async throws {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        lastError = nil
        try await performDisable()
    }

    /// 还原实现（调用方负责 `isTransitioning`）
    private func performDisable() async throws {
        let url = snapshotURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try Networksetup.deactivate(snapshotURL: url)
            }.value
            isEnabled = false
            lastError = nil
            systemProxyLogger.notice("系统代理已还原")
        } catch {
            let mapped = Self.mapped(error)
            lastError = mapped
            // 还原没走完：快照必须留着（下次启动兜底）
            isEnabled = FileManager.default.fileExists(atPath: url.path)
            systemProxyLogger.error("还原系统代理失败：\(mapped.logDescription, privacy: .public)，保留快照")
            throw mapped
        }
    }

    /// App 启动兜底：快照存在 且 内核未运行 → 立即还原（`system-proxy` §6 不变式）
    func restoreIfNeeded(kernelRunning: Bool) async {
        guard hasSnapshot else {
            isEnabled = false
            return
        }
        guard !kernelRunning else {
            // 内核还活着，代理有效：等正常关闭时再还原
            isEnabled = true
            return
        }
        do {
            try await disable()
            systemProxyLogger.notice("启动兜底：已还原上次遗留的系统代理")
        } catch {
            systemProxyLogger.error("启动兜底还原失败：\(Self.mapped(error).logDescription, privacy: .public)")
        }
    }

    /// App 退出路径（`willTerminate`，无法 await）：同步还原，失败则保留快照并记日志。
    ///
    /// 调用方必须先调它、再停内核（顺序不能反，否则内核先死会留下指向死端口的代理）。
    func disableSynchronouslyForTermination() {
        guard hasSnapshot else {
            isEnabled = false
            return
        }
        do {
            try Networksetup.deactivate(snapshotURL: snapshotURL)
            isEnabled = false
            systemProxyLogger.notice("退出前已还原系统代理")
        } catch {
            systemProxyLogger.error(
                "退出前还原系统代理失败：\(Self.mapped(error).logDescription, privacy: .public)，保留快照交给下次启动"
            )
        }
    }

    /// 失败兜底：快照还在就再还原一次，避免系统代理停在半开状态
    private func forceRestoreIfSnapshotExists() {
        guard hasSnapshot else { return }
        do {
            try Networksetup.deactivate(snapshotURL: snapshotURL)
            isEnabled = false
            systemProxyLogger.notice("失败兜底：系统代理已按快照还原")
        } catch {
            isEnabled = true
            systemProxyLogger.error(
                "失败兜底还原未完成：\(Self.mapped(error).logDescription, privacy: .public)，保留快照"
            )
        }
    }

    // MARK: - 错误

    private func report(_ error: Error) -> SystemProxyError {
        let mapped = Self.mapped(error)
        lastError = mapped
        return mapped
    }

    private static func mapped(_ error: Error) -> SystemProxyError {
        (error as? SystemProxyError) ?? .commandFailed(service: "系统代理", detail: String(describing: error))
    }

    #if DEBUG
    /// 自检夹具：让读回校验失败，用来验证「失败必回滚」。只在 `SystemProxyHarness` 里打开。
    var debugFailVerification = false
    #endif
}

// MARK: - 快照模型（`system-proxy` §3）

/// web / secure / socks 的单个代理项。`enabled: false` 时 server/port 仍可能是用户留下的旧值，
/// 必须一并记录：`-setxxxstate off` 并不清理这两个字段，只还原开关会把用户的旧配置抹成我们的端口。
struct ProxyEndpoint: Codable, Sendable, Equatable {
    var enabled: Bool
    var server: String
    var port: Int
}

/// PAC（`-getautoproxyurl`）。v1 不主动设置 PAC，只负责「开代理时关掉、还原时写回」。
struct ProxyAutoConfig: Codable, Sendable, Equatable {
    var enabled: Bool
    var url: String
}

/// 单个网络服务的全部代理项（快照里的一行）
struct ServiceProxyState: Codable, Sendable, Equatable {
    var name: String
    var web: ProxyEndpoint
    var secure: ProxyEndpoint
    var socks: ProxyEndpoint
    var auto: ProxyAutoConfig
    /// 例外域名；未设置时为 `[]`（`-getproxybypassdomains` 只输出一个空行）
    var bypass: [String]
}

/// 系统代理快照：唯一真相。字段与 `system-proxy` §3 一致。
struct SystemProxySnapshot: Codable, Sendable, Equatable {
    var version: Int
    var createdAt: Date
    var kernelPort: Int
    var services: [ServiceProxyState]
}

// MARK: - 错误分类

enum SystemProxyError: Error, Equatable, Sendable {
    /// 非管理员账号 / MDM 策略锁定：命令返回权限错误
    case notAdmin(command: String, detail: String)
    /// 某条 networksetup 命令失败
    case commandFailed(service: String, detail: String)
    /// 写入后读回不一致（已回滚）
    case verificationFailed(service: String, detail: String)
    /// 关闭时找不到快照
    case snapshotMissing
    case snapshotUnreadable(detail: String)
    /// 快照写盘失败：此时系统代理**尚未被改动**
    case snapshotWriteFailed(detail: String)
    case snapshotRemoveFailed(detail: String)
    /// 一个可用的网络服务都没找到
    case noServices

    /// 面向用户的一句话（banner / 磁贴）
    var userMessage: String {
        switch self {
        case .notAdmin:
            "需要管理员账号才能修改系统代理"
        case .commandFailed(let service, _):
            "修改「\(service)」的代理设置失败"
        case .verificationFailed(let service, _):
            "「\(service)」的代理设置未生效，已回滚"
        case .snapshotMissing:
            "缺少代理快照，无法还原系统代理，请到系统设置里手动关闭"
        case .snapshotUnreadable:
            "代理快照损坏，无法自动还原，请到系统设置里手动关闭代理"
        case .snapshotWriteFailed:
            "无法写入代理快照，已取消操作（系统代理未改动）"
        case .snapshotRemoveFailed:
            "系统代理已还原，但快照删除失败，下次启动会再核对一次"
        case .noServices:
            "没有找到可用的网络服务"
        }
    }

    /// 只进日志的细节
    var logDescription: String {
        switch self {
        case .notAdmin(let command, let detail):
            "notAdmin（\(command)：\(detail)）"
        case .commandFailed(let service, let detail):
            "commandFailed（\(service)：\(detail)）"
        case .verificationFailed(let service, let detail):
            "verificationFailed（\(service)：\(detail)）"
        case .snapshotMissing:
            "snapshotMissing（关闭时没有快照）"
        case .snapshotUnreadable(let detail):
            "snapshotUnreadable（\(detail)）"
        case .snapshotWriteFailed(let detail):
            "snapshotWriteFailed（\(detail)）"
        case .snapshotRemoveFailed(let detail):
            "snapshotRemoveFailed（\(detail)）"
        case .noServices:
            "noServices（-listallnetworkservices 没有返回启用的服务）"
        }
    }
}

// MARK: - networksetup 事务（同步实现，供后台线程与退出路径共用）

/// 所有系统写入都收敛在这里：先快照、再设置、再读回校验，失败一律按快照回滚。
///
/// 同步实现是为了 `willTerminate` 里也能直接调用；异步调用方把它丢到后台线程，
/// 避免 `networksetup` 的几十毫秒阻塞主线程。
private enum Networksetup {

    static let toolPath = "/usr/sbin/networksetup"
    /// 本机地址写死：不暴露到局域网（`allow-lan` 只影响代理端口）
    static let localServer = "127.0.0.1"

    /// v0.2 没有 SOCKS 设置项：默认不接管 SOCKS（避免覆盖用户自建的 socks 代理）。
    /// TODO(v0.2+): 设置项「同时代理 SOCKS」打开后再置 `true`，并同步打开读回校验。
    static let configuresSOCKS = false

    enum ProxyKind {
        case web
        case secure
        case socks

        var getCommand: String {
            switch self {
            case .web: "-getwebproxy"
            case .secure: "-getsecurewebproxy"
            case .socks: "-getsocksfirewallproxy"
            }
        }

        var setCommand: String {
            switch self {
            case .web: "-setwebproxy"
            case .secure: "-setsecurewebproxy"
            case .socks: "-setsocksfirewallproxy"
            }
        }

        var setStateCommand: String {
            switch self {
            case .web: "-setwebproxystate"
            case .secure: "-setsecurewebproxystate"
            case .socks: "-setsocksfirewallproxystate"
            }
        }

        var displayName: String {
            switch self {
            case .web: "HTTP"
            case .secure: "HTTPS"
            case .socks: "SOCKS"
            }
        }
    }

    struct CommandResult: Sendable {
        let status: Int32
        let output: String

        var succeeded: Bool {
            status == 0 && !output.localizedCaseInsensitiveContains("** Error")
        }
    }

    // MARK: 命令执行

    static func execute(_ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    static func run(_ arguments: [String], service: String) throws -> String {
        let result = execute(arguments)
        try check(result, arguments: arguments, service: service)
        return result.output
    }

    static func check(_ result: CommandResult, arguments: [String], service: String) throws {
        guard !result.succeeded else { return }

        let command = arguments.first ?? "networksetup"
        let detail = clipped(result.output)
        if looksLikePermissionProblem(result.output) {
            throw SystemProxyError.notAdmin(command: command, detail: detail)
        }
        throw SystemProxyError.commandFailed(service: service, detail: "\(command) exit=\(result.status) \(detail)")
    }

    /// 只看关键字，不解析文本：非管理员 / 授权被拒 / MDM 锁定时 networksetup 的措辞会变
    static func looksLikePermissionProblem(_ output: String) -> Bool {
        let lower = output.lowercased()
        let keywords = ["must be root", "permission denied", "not authorized", "not permitted",
                        "administrator", "authorization failed", "sudo"]
        return keywords.contains { lower.contains($0) }
    }

    static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 300 else { return trimmed }
        return String(trimmed.prefix(300)) + "…"
    }

    // MARK: 枚举与采集

    /// 首行是说明文字；`*` 开头 = 服务已停用，跳过（`system-proxy` §2）
    static func listServices() throws -> [String] {
        let output = try run(["-listallnetworkservices"], service: "网络服务列表")
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let names = lines.dropFirst().filter { line in
            !line.isEmpty
                && !line.hasPrefix("*")
                && !line.localizedCaseInsensitiveContains("asterisk")
        }
        guard !names.isEmpty else { throw SystemProxyError.noServices }
        return names
    }

    static func capture(kernelPort: Int) throws -> SystemProxySnapshot {
        let names = try listServices()
        let services = try names.map(readState)
        return SystemProxySnapshot(
            version: 1,
            createdAt: Date(),
            kernelPort: kernelPort,
            services: services
        )
    }

    static func readState(_ name: String) throws -> ServiceProxyState {
        ServiceProxyState(
            name: name,
            web: parseProxy(try run([ProxyKind.web.getCommand, name], service: name)),
            secure: parseProxy(try run([ProxyKind.secure.getCommand, name], service: name)),
            socks: parseProxy(try run([ProxyKind.socks.getCommand, name], service: name)),
            auto: parseAuto(try run(["-getautoproxyurl", name], service: name)),
            bypass: parseBypass(try run(["-getproxybypassdomains", name], service: name))
        )
    }

    // MARK: 解析

    /// `Enabled: Yes|No` / `Server: x` / `Port: n`
    static func parseProxy(_ output: String) -> ProxyEndpoint {
        var endpoint = ProxyEndpoint(enabled: false, server: "", port: 0)
        for (key, value) in keyValueLines(output) {
            switch key {
            case "enabled": endpoint.enabled = value.lowercased() == "yes"
            case "server": endpoint.server = normalized(value)
            case "port": endpoint.port = Int(value) ?? 0
            default: break
            }
        }
        return endpoint
    }

    /// `URL: x` / `Enabled: Yes|No`；URL 未设置时是 `(null)`
    static func parseAuto(_ output: String) -> ProxyAutoConfig {
        var config = ProxyAutoConfig(enabled: false, url: "")
        for (key, value) in keyValueLines(output) {
            switch key {
            case "enabled": config.enabled = value.lowercased() == "yes"
            case "url": config.url = normalized(value)
            default: break
            }
        }
        return config
    }

    static func parseBypass(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                // 未设置时旧版本会输出 "There aren't any bypass domains set on <service>."
                !line.isEmpty && !line.localizedCaseInsensitiveContains("bypass domains")
            }
    }

    private static func keyValueLines(_ output: String) -> [(String, String)] {
        output.split(separator: "\n").compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let key = line[line.startIndex ..< separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed == "(null)" ? "" : trimmed
    }

    // MARK: 快照落盘

    static func save(_ snapshot: SystemProxySnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try AtomicFile.write(data, to: url, permissions: 0o600)
        } catch {
            throw SystemProxyError.snapshotWriteFailed(detail: error.localizedDescription)
        }
    }

    static func load(from url: URL) throws -> SystemProxySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SystemProxySnapshot.self, from: data)
        } catch {
            throw SystemProxyError.snapshotUnreadable(detail: error.localizedDescription)
        }
    }

    static func removeSnapshot(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SystemProxyError.snapshotRemoveFailed(detail: error.localizedDescription)
        }
    }

    // MARK: 开启事务

    /// 采集 → 落盘 → 逐服务写入 → 读回校验；任一步失败按快照回滚。
    /// 快照写盘失败时直接抛错：此时系统代理一个字都没改。
    static func activate(port: Int, snapshotURL: URL, failVerification: Bool = false) throws {
        let snapshot = try capture(kernelPort: port)
        try save(snapshot, to: snapshotURL)

        do {
            for service in snapshot.services {
                try setProxy(service.name, port: port)
            }
            if failVerification {
                throw SystemProxyError.verificationFailed(service: snapshot.services.first?.name ?? "系统代理", detail: "自检注入")
            }
            try verifyProxied(snapshot.services.map(\.name), port: port)
        } catch {
            rollback(snapshot, snapshotURL: snapshotURL)
            throw error
        }
    }

    private static func setProxy(_ name: String, port: Int) throws {
        try run([ProxyKind.web.setCommand, name, localServer, String(port)], service: name)
        try run([ProxyKind.secure.setCommand, name, localServer, String(port)], service: name)
        if configuresSOCKS {
            try run([ProxyKind.socks.setCommand, name, localServer, String(port)], service: name)
        }
        // PAC 会绕过我们的 HTTP 代理，必须关掉
        try run(["-setautoproxystate", name, "off"], service: name)
    }

    /// 读一个服务的单项代理设置
    static func endpoint(of kind: ProxyKind, service name: String) throws -> ProxyEndpoint {
        parseProxy(try run([kind.getCommand, name], service: name))
    }

    /// 面板「代理中」的唯一判据：每个服务的 HTTP / HTTPS 都指向 127.0.0.1:<port> 且已启用
    static func verifyProxied(_ names: [String], port: Int) throws {
        for name in names {
            for kind in [ProxyKind.web, .secure] {
                let endpoint = try endpoint(of: kind, service: name)
                guard endpoint.enabled else {
                    throw SystemProxyError.verificationFailed(service: name, detail: "\(kind.displayName) 未启用")
                }
                guard endpoint.server == localServer, endpoint.port == port else {
                    throw SystemProxyError.verificationFailed(
                        service: name,
                        detail: "\(kind.displayName) 读回为 \(endpoint.server):\(endpoint.port)"
                    )
                }
            }
            if configuresSOCKS {
                let socks = try endpoint(of: .socks, service: name)
                guard socks.enabled, socks.server == localServer, socks.port == port else {
                    throw SystemProxyError.verificationFailed(service: name, detail: "SOCKS 读回不一致")
                }
            }
            let auto = parseAuto(try run(["-getautoproxyurl", name], service: name))
            guard !auto.enabled else {
                throw SystemProxyError.verificationFailed(service: name, detail: "PAC 仍处于开启状态")
            }
        }
    }

    // MARK: 还原事务

    /// 读快照 → 逐项还原 → 读回校验 → 删快照
    static func deactivate(snapshotURL: URL) throws {
        guard let snapshot = try load(from: snapshotURL) else {
            throw SystemProxyError.snapshotMissing
        }
        try restore(snapshot)
        try removeSnapshot(at: snapshotURL)
    }

    /// 逐服务还原；一个服务失败不阻断其余服务（尽量把能还原的都还原掉），最后再抛第一个错误
    static func restore(_ snapshot: SystemProxySnapshot) throws {
        var firstError: SystemProxyError?
        for service in snapshot.services {
            do {
                try restore(service: service)
            } catch {
                if firstError == nil { firstError = error as? SystemProxyError ?? .commandFailed(service: service.name, detail: String(describing: error)) }
            }
        }
        if let firstError { throw firstError }

        for service in snapshot.services {
            try verifyRestored(service)
        }
    }

    static func restore(service: ServiceProxyState) throws {
        try restoreProxy(service.name, kind: .web, endpoint: service.web)
        try restoreProxy(service.name, kind: .secure, endpoint: service.secure)
        try restoreProxy(service.name, kind: .socks, endpoint: service.socks)
        try restoreAuto(service.name, config: service.auto)
        try restoreBypass(service.name, domains: service.bypass)
    }

    /// 先按原 server/port 写回（没有就写空串 0），再按原状态开关。
    /// 顺序不能反：`-setxxxstate off` 不会清掉 server/port，只写 state 会留下我们的端口。
    private static func restoreProxy(_ name: String, kind: ProxyKind, endpoint: ProxyEndpoint) throws {
        try run([kind.setCommand, name, endpoint.server, String(endpoint.port)], service: name)
        if !endpoint.enabled {
            try run([kind.setStateCommand, name, "off"], service: name)
        }
    }

    private static func restoreAuto(_ name: String, config: ProxyAutoConfig) throws {
        if !config.url.isEmpty {
            try run(["-setautoproxyurl", name, config.url], service: name)
        }
        try run(["-setautoproxystate", name, config.enabled ? "on" : "off"], service: name)
    }

    /// 空列表的处理（实测 macOS 15.7）：
    /// - 不带域名参数 → `** Error: The amount of parameters was not correct.`（exit 3），不能用
    /// - 传单个空串 → exit 0，`-getproxybypassdomains` 读回为空，与「未设置」等价
    /// 所以「原本没有例外域名」时用 `""` 还原，读回的域名集合与快照一致。
    private static func restoreBypass(_ name: String, domains: [String]) throws {
        let effective = domains.filter { !$0.isEmpty }
        if effective.isEmpty {
            try run(["-setproxybypassdomains", name, ""], service: name)
        } else {
            try run(["-setproxybypassdomains", name] + effective, service: name)
        }
    }

    static func verifyRestored(_ expected: ServiceProxyState) throws {
        let current = try readState(expected.name)

        for (expectedEndpoint, actualEndpoint, label) in [
            (expected.web, current.web, ProxyKind.web.displayName),
            (expected.secure, current.secure, ProxyKind.secure.displayName),
            (expected.socks, current.socks, ProxyKind.socks.displayName),
        ] {
            guard actualEndpoint == expectedEndpoint else {
                throw SystemProxyError.verificationFailed(
                    service: expected.name,
                    detail: "\(label) 未还原（读回 \(actualEndpoint.server):\(actualEndpoint.port) enabled=\(actualEndpoint.enabled)）"
                )
            }
        }

        guard current.auto.enabled == expected.auto.enabled,
              expected.auto.url.isEmpty || current.auto.url == expected.auto.url else {
            throw SystemProxyError.verificationFailed(service: expected.name, detail: "PAC 未还原")
        }

        let expectedBypass = expected.bypass.filter { !$0.isEmpty }
        guard current.bypass.filter({ !$0.isEmpty }) == expectedBypass else {
            throw SystemProxyError.verificationFailed(service: expected.name, detail: "例外域名未还原")
        }
    }

    /// 回滚成功后删快照；回滚失败保留快照（下次启动兜底），并记下真实原因
    private static func rollback(_ snapshot: SystemProxySnapshot, snapshotURL: URL) {
        do {
            try restore(snapshot)
            try removeSnapshot(at: snapshotURL)
            systemProxyLogger.notice("开启失败，已按快照回滚")
        } catch {
            systemProxyLogger.error(
                "开启失败且回滚未完成：\(String(describing: error), privacy: .public)，保留快照等待下次启动兜底"
            )
        }
    }
}

private let systemProxyLogger = Logger(subsystem: "com.clash.app", category: "systemproxy")
