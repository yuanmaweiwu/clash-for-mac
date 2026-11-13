import Foundation

/// 内核进程状态（唯一来源：`KernelService`）。
///
/// `starting` 覆盖「校验 + 拉起 + 就绪探测」全过程；`stopping` 由
/// `KernelService.isTransitioning` 表达，UI 侧不再单列状态值。
enum KernelPhase: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}
