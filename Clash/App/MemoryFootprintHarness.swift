#if DEBUG
import Darwin
import Foundation

/// 面板内存台阶归因夹具（仅 DEBUG）：`CLASH_MEMORY_HARNESS=1`。
///
/// 复跑「新进程 → 打开面板 → 进设置页 → 返回 → 收起 → 丢弃 SwiftUI 树」六个阶段，
/// 每阶段打印 `MEM stage=… footprint=…`，并在关键阶段停 6s：外部可趁停顿
/// `vmmap -summary <pid>` / `heap <pid>` 采样同一进程，判断台阶属于
/// AttributeGraph / 字体缓存还是我们自己的数据。
///
/// 只用 `phys_footprint`（与 `footprint` / Activity Monitor 同口径），不引第三方依赖。
@MainActor
enum MemoryFootprintHarness {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CLASH_MEMORY_HARNESS"] == "1"
    }

    static func runIfRequested() -> Bool {
        guard isRequested else { return false }
        Task { @MainActor in await run() }
        return true
    }

    private static func run() async {
        let environment = AppEnvironment.shared
        let pid = ProcessInfo.processInfo.processIdentifier
        print("MEM pid=\(pid)（每阶段停 6s，可用 vmmap -summary \(pid) 采样）")
        report("boot", pid: pid)

        environment.showPanel()
        await settle(2)
        report("panel", pid: pid)
        await hold()

        environment.model.openSettingsPage()
        await settle(2)
        report("settings", pid: pid)
        await hold()

        environment.model.popRoute()
        await settle(2)
        report("after-pop", pid: pid)
        await hold()

        environment.panel.hide()
        await settle(3)
        report("after-hide", pid: pid)
        await hold()

        // 归因实验：整棵 SwiftUI 树丢掉后 footprint 还不回落，说明台阶在框架全局缓存，
        // 单纯「离开设置路由时重建视图」压不下去。
        environment.panel.releaseSwiftUIForMemoryAudit()
        await settle(3)
        report("after-release", pid: pid)

        // 归因实验 2：把 malloc 空页交还系统。若 footprint 明显回落，说明台阶是
        // 一次性分配器扩张（空闲页仍算 dirty），可以在「面板收起」时做一次压力回收。
        let relieved = malloc_zone_pressure_relief(nil, 0)
        await settle(3)
        print("MEM malloc_zone_pressure_relief=\(relieved) bytes")
        report("after-pressure", pid: pid)
        await hold()

        exit(0)
    }

    private static func report(_ stage: String, pid: Int32) {
        let bytes = footprintBytes()
        let mb = Double(bytes) / 1_048_576
        print(String(format: "MEM stage=%@ pid=%d footprint=%.1fMB bytes=%llu", stage, pid, mb, bytes))
        fflush(stdout)
    }

    private static func hold() async {
        try? await Task.sleep(for: .seconds(6))
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// `TASK_VM_INFO.phys_footprint`：与 `footprint(1)` 同口径
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
