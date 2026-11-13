// TODO(v0.2): 接 helper 授权后再启用；v0.1 的 TUN 磁贴恒为「需要管理员组件」，
// 不读也不写本枚举（见 Features/Panel/TunTileView.swift）
import Foundation

/// TUN 磁贴的五态（§4.2）。v0.1 不驱动；接入管理员组件后由真实授权流程填充。
enum TunState: String, Sendable {
    case off
    case requiresAuth
    case waitingAuth
    case on
    case authFailed
}
