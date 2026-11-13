// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// 内核进程的五态（演示用，不接触真实进程）。
enum KernelPhase: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}
