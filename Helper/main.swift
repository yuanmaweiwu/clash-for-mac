import Foundation

// ClashHelper：以 root 常驻的 LaunchDaemon（`adr/0008`）。
//
// 生命周期由 launchd 管理（`RunAtLoad` + `KeepAlive`），这里只负责挂上 mach service
// 然后进 run loop。除 `HelperLayout` 里的固定路径外不读任何调用方输入。

let listener = NSXPCListener(machServiceName: HelperLayout.machServiceName)
let service = HelperService()
listener.delegate = service
listener.resume()

// `NSXPCListener.delegate` 是 weak，扩展生命周期到 run loop 结束
withExtendedLifetime(service) {
    RunLoop.current.run()
}
