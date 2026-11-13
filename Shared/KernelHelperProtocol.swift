import Foundation

/// Helper 协议版本。App 与 helper 不一致 → App 侧提示「组件需要更新」，下次授权时覆盖安装
/// （`adr/0008` §版本升级）。加方法 / 改语义必须 +1。
let HelperVersion = 1

/// App 与 helper 唯一共用的固定布局（`docs/01-ARCHITECTURE.md` §7）。
///
/// **路径一律不通过 XPC 传递**：helper 自己从这里推导，App 只负责安装时把二进制放到位。
/// 任何「让调用方指定二进制 / 配置路径」的接口都等于给 root 开后门，禁止。
enum HelperLayout {

    /// launchd 的 job label，同时也是 `MachServices` 里注册的 mach service 名
    static let machServiceName = "com.clash.helper"

    // MARK: 安装后的固定位置（root:wheel）

    /// helper 可执行文件
    static let helperToolPath = "/Library/PrivilegedHelperTools/com.clash.helper"
    /// 内核二进制（TUN 需要 root，故与 helper 同目录，便于统一 chown）
    static let kernelToolPath = "/Library/PrivilegedHelperTools/mihomo"
    /// 运行目录：runtime.yaml、kernel.log、geodata 都在这里（root 独占，App 不可写）
    static let supportDirectory = "/Library/Application Support/ClashHelper"
    /// helper 自己消费的最终配置（TUN 接入时由 helper 写）
    static let runtimeConfigPath = supportDirectory + "/runtime.yaml"
    /// mihomo 的 stdout / stderr
    static let kernelLogPath = supportDirectory + "/kernel.log"
    /// LaunchDaemon 定义
    static let daemonPlistPath = "/Library/LaunchDaemons/com.clash.helper.plist"

    // MARK: App 包内相对路径（安装脚本从这里拷）

    static let bundledHelperRelativePath = "Contents/Library/PrivilegedHelperTools/com.clash.helper"
    static let bundledKernelRelativePath = "Contents/Resources/Kernel/mihomo"

    /// 客户端可执行路径白名单后缀：ad-hoc 签名没有 team id，只能先比路径（弱校验，见 `adr/0008`）
    static let allowedClientPathSuffix = "/Clash.app/Contents/MacOS/Clash"
}

/// App ⇄ helper 的白名单接口（`adr/0008`）。**只有这四个方法，不接受任意命令 / 任意路径。**
///
/// 全部参数由 helper 自己推导：内核用 `HelperLayout.kernelToolPath`，
/// 配置用 `HelperLayout.runtimeConfigPath`。
@objc(KernelHelperProtocol)
protocol KernelHelperProtocol {

    /// 协议版本号（`HelperVersion` 的十进制字符串）。App 用它判断 helper 是否需要更新。
    func ping(_ reply: @escaping (String) -> Void)

    /// 以 root 启动 mihomo。成功 → `(true, "pid=<pid>")`；失败 → `(false, 原因)`。
    /// 已有实例在跑 → 直接返回既有 pid，不重复 spawn。
    func startKernel(_ reply: @escaping (Bool, String?) -> Void)

    /// `SIGTERM` → 等 3s → 仍活则 `SIGKILL`。`true` = 已确认没有内核进程。
    func stopKernel(_ reply: @escaping (Bool) -> Void)

    /// 当前状态。运行中 → `(true, "<pid>")`；未运行 → `(false, nil)`。
    func kernelState(_ reply: @escaping (Bool, String?) -> Void)
}
