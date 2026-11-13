import Foundation

/// 内核进程的五态（演示用，不接触真实进程）。
enum KernelPhase: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}
