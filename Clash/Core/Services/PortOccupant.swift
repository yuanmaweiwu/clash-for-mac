import Darwin
import Foundation
import OSLog

/// 端口占用者：`portInUse` 的文案要写「谁占着」，自动重试要判断「是不是我们自己的内核」。
///
/// 只承载诊断信息，不持有任何句柄；`Sendable` 以便从 `lsof` 的后台任务里带回来。
struct PortOccupant: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 本产品内核：`~/Library/Application Support/Clash/kernel/mihomo`
        /// （ADR-0012 起二进制在用户目录，所有构建共用同一份）
        case productKernel
        /// helper 的 root 内核（只在 TUN 模式下存在）：**只检测、绝不杀**
        case tunKernel
        /// 别家程序（ClashX / Clash Verge / 用户自己跑的 mihomo…）
        case other
    }

    let pid: pid_t
    /// 进程名（可执行文件 basename；取不到时退回 `lsof` 的命令名）
    let name: String
    let executablePath: String?
    let kind: Kind

    var isProductKernel: Bool { kind == .productKernel }

    /// 文案用：`mihomo (pid 49329)`
    var summary: String { "\(name) (pid \(pid))" }
}

/// 本产品内核的路径判据（孤儿回收与端口诊断共用一份，避免两处口径分叉）。
///
/// 不能用进程名，也不能用 `contains("Clash")`：ClashX / Clash Verge 的内核同名，
/// 且 `Clash Verge.app` 的路径里同样含 "Clash"，按模糊匹配会误杀别人的内核。
enum KernelProcessIdentity {

    /// 本产品内核的路径后缀。
    ///
    /// 判据是**路径段精确匹配**：`~/Library/Application Support/Clash/kernel/mihomo`
    /// （ADR-0012：内核下载到用户目录，不再位于 `.app` 内）。
    /// - 不命中：`/Applications/Clash Verge.app/…`、用户自己的 mihomo 副本
    static let productPathSuffix = "/Library/Application Support/Clash/kernel/mihomo"

    /// helper 的 root 内核（TUN）：不在 App 里，杀不掉也不该杀，仅用于给出明确错误
    static let helperPath = "/Library/PrivilegedHelperTools/mihomo"

    /// `/var` ↔ `/private/var`、软链接、`..` 统一后再比较
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isProductKernel(path: String) -> Bool {
        canonicalPath(path).hasSuffix(productPathSuffix)
    }

    static func isHelperKernel(path: String) -> Bool {
        canonicalPath(path) == helperPath
    }

    static func kind(forPath path: String?) -> PortOccupant.Kind {
        guard let path else { return .other }
        if isProductKernel(path: path) { return .productKernel }
        if isHelperKernel(path: path) { return .tunKernel }
        return .other
    }

    /// `proc_pidpath`：取进程可执行文件路径（同用户进程可靠；root 进程可能拿不到 → nil）
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

/// 查「谁在监听某个端口」：`lsof -Fpc` 拿 pid / 命令名，可执行路径再用 `proc_pidpath` 取。
///
/// 任何一步失败都返回 nil —— 调用方退回通用文案，绝不让诊断把启动流程卡住。
enum PortOccupantProbe {

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")
    private static let lsofURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    /// `lsof` 正常 <100ms；给 2s 上限，超时就当查不到
    private static let lookupTimeout: TimeInterval = 2

    private struct Listener: Sendable {
        let pid: pid_t
        let command: String
    }

    /// 监听该端口的进程；多个（v4/v6 双栈、多进程）时优先返回本产品的内核。
    static func listener(onPort port: Int) async -> PortOccupant? {
        guard (1...65535).contains(port) else { return nil }

        let listeners = await listeningProcesses(onPort: port)
        let occupants = listeners.map { listener -> PortOccupant in
            let path = KernelProcessIdentity.executablePath(of: listener.pid)
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? listener.command
            return PortOccupant(
                pid: listener.pid,
                name: name,
                executablePath: path,
                kind: KernelProcessIdentity.kind(forPath: path)
            )
        }
        return occupants.first(where: \.isProductKernel) ?? occupants.first
    }

    // MARK: - lsof

    private static func listeningProcesses(onPort port: Int) async -> [Listener] {
        await Task.detached(priority: .userInitiated) { () -> [Listener] in
            guard FileManager.default.isExecutableFile(atPath: lsofURL.path) else {
                logger.error("找不到 /usr/sbin/lsof，端口占用者未知")
                return []
            }

            let process = Process()
            process.executableURL = lsofURL
            // -F p c：机器可解析输出（p<pid> / c<command>），不解析表格列宽
            process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                logger.error("lsof 启动失败：\(error.localizedDescription, privacy: .public)")
                return []
            }

            let deadline = Date().addingTimeInterval(lookupTimeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning { process.terminate() }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    private static func parse(_ output: String) -> [Listener] {
        var listeners: [Listener] = []
        var currentPID: pid_t?
        var currentCommand = ""

        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())

            switch field {
            case "p":
                if let pid = currentPID, pid > 0 {
                    listeners.append(Listener(pid: pid, command: currentCommand))
                }
                currentPID = pid_t(value)
                currentCommand = ""
            case "c":
                currentCommand = value
            default:
                continue
            }
        }

        if let pid = currentPID, pid > 0 {
            listeners.append(Listener(pid: pid, command: currentCommand))
        }
        return listeners
    }
}
