// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// TUN 磁贴的五态（§4.2），全部本地模拟。
enum TunState: String, Sendable {
    case off
    case requiresAuth
    case waitingAuth
    case on
    case authFailed
}
