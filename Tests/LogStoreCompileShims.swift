import Foundation

/// 只为让 `LogStore.swift` 能在单测进程里编译的**替身**，不参与被断言的逻辑。
///
/// `LogStore.swift` 里同时住着 `LogStore`（@MainActor、连 WS、依赖 `KernelService`）
/// 和 `LogRedactor`（纯字符串函数，本目录要测的就是它）。`LogRedactor` 目前没有独立
/// 源文件，所以必须把整个文件喂给 `swiftc`；而真正的 `KernelService` 会拖进 AppKit /
/// 内核进程管理。这里按 `LogStore` 实际用到的最小接口给出替身：
/// 被测代码仍是仓库里那份 `LogRedactor`，替身只填编译期依赖。
///
/// 真 `KernelService` / `ClashAPIClient` 的接口若变了，`LogStore.swift` 编译会失败并
/// 提示这里的签名过期——那正是需要更新替身的信号。

@MainActor
final class KernelService {
    var phase: KernelPhase = .stopped
    var port: Int?
    var secret: String?
}

actor ClashAPIClient {
    init(port: Int, secret: String) {}

    func logs(level: String) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stopLogs() {}
}

/// `KernelError.provisioning` 的关联类型替身。
///
/// 真实现住在 `KernelProvisioner.swift`（下载 / 解压 / 校验 / GitHub release 检查），
/// 会拖进 URLSession 与几百行下载逻辑。被测代码只抛 `KernelError.configInvalid`，
/// 从不构造 `provisioning`，所以只需要一个能让 `KernelError.swift` 编译的形状。
enum KernelProvisionError: Error, Equatable, Sendable {
    case network(String)

    var userMessage: String { "内核下载失败" }
    var logDescription: String { "provisioning（替身，未参与断言）" }
}
