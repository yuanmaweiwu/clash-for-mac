import Foundation

// ClashHelper：以 root 常驻的 LaunchDaemon（`adr/0008`）。
//
// 生命周期由 launchd 管理（`RunAtLoad` + `KeepAlive`），这里只负责挂上 mach service
// 然后进 run loop。除 `HelperLayout` 里的固定路径外不读任何调用方输入。

#if DEBUG
// 自检入口（`CLASH_HELPER_SELFCHECK=1`）：只跑纯函数判定表，不挂 XPC、不碰 root 目录
if HelperSelfCheck.runIfRequested() { exit(0) }
#endif

// 挂监听前先回收上一个 helper 遗留的 root 内核（AUDIT A7）：新 helper 还没有子进程，
// 路径命中的一定是孤儿；不先清掉，新内核会撞上它占着的 mixed-port。
KernelOrphanReaper.reapOrphans()

let listener = NSXPCListener(machServiceName: HelperLayout.machServiceName)
let service = HelperService()
listener.delegate = service
listener.resume()

// `NSXPCListener.delegate` 是 weak，扩展生命周期到 run loop 结束
withExtendedLifetime(service) {
    RunLoop.current.run()
}
