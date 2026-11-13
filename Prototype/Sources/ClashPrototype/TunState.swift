import Foundation

/// TUN 磁贴的五态（§4.2），全部本地模拟。
enum TunState: String, Sendable {
    case off
    case requiresAuth
    case waitingAuth
    case on
    case authFailed
}
