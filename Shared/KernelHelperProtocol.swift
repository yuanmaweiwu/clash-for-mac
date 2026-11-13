import Foundation

/// Helper 协议版本。App 与 helper 不一致 → App 侧提示「组件需要更新」，下次授权时覆盖安装
/// （`adr/0008` §版本升级）。加方法 / 改语义必须 +1。
///
/// v2（TUN）：新增 `applyRuntimeConfig`，配置正文改由 App 经 XPC 送达（不再让 helper 读 App 目录）。
let HelperVersion = 2

/// 运行配置正文上限。Yams 解析要整段读进内存，超过这个量级只可能是误传 / 恶意输入。
/// App 与 helper 用同一个常量，两边都能在发送前 / 写入前拒绝。
let HelperMaxRuntimeConfigBytes = 5 * 1024 * 1024

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
    /// helper 自己消费的最终配置：**正文由 App 送来，helper 负责校验 + 原子落盘**
    static let runtimeConfigPath = supportDirectory + "/runtime.yaml"
    /// mihomo 的 stdout / stderr
    static let kernelLogPath = supportDirectory + "/kernel.log"
    /// helper 自己的日志（unified log 的落盘副本；plist 的 `StandardOutPath` 同路径）
    static let helperLogPath = supportDirectory + "/helper.log"
    /// LaunchDaemon 定义
    static let daemonPlistPath = "/Library/LaunchDaemons/com.clash.helper.plist"

    // MARK: App 包内相对路径（安装脚本从这里拷）

    static let bundledHelperRelativePath = "Contents/Library/PrivilegedHelperTools/com.clash.helper"

    /// 客户端可执行路径白名单后缀：ad-hoc 签名没有 team id，只能先比路径（弱校验，见 `adr/0008`）
    static let allowedClientPathSuffix = "/Clash.app/Contents/MacOS/Clash"
}

/// App ⇄ helper 的白名单接口（`adr/0008`）。**只有这五个方法，不接受任意命令 / 任意路径。**
///
/// 参数面仍然是封闭的：唯一传入的内容是「配置正文」，落盘位置由 helper 推导
/// （`HelperLayout.runtimeConfigPath`），内核二进制固定 `HelperLayout.kernelToolPath`。
@objc(KernelHelperProtocol)
protocol KernelHelperProtocol {

    /// 协议版本号（`HelperVersion` 的十进制字符串）。App 用它判断 helper 是否需要更新。
    func ping(_ reply: @escaping (String) -> Void)

    /// 应用运行配置（v2）：校验 → 原子写 `runtime.yaml`（0600 root:wheel）→ **不启动内核**。
    ///
    /// 拒绝：空正文、超过 `HelperMaxRuntimeConfigBytes`、非 UTF-8、非法 YAML、顶层不是映射。
    /// 成功 → `(true, nil)`；失败 → `(false, 中文原因)`。
    /// 拆成「写配置」与「启内核」两步，是为了让 App 能在启动前确认写盘结果，
    /// 失败时不必先起内核再回滚。
    func applyRuntimeConfig(_ bytes: Data, reply: @escaping (Bool, String?) -> Void)

    /// 以 root 启动 mihomo。成功 → `(true, "pid=<pid>")`；失败 → `(false, 原因)`。
    /// 已有实例在跑 → 直接返回既有 pid，不重复 spawn。
    func startKernel(_ reply: @escaping (Bool, String?) -> Void)

    /// `SIGTERM` → 等 3s → 仍活则 `SIGKILL`。`true` = 已确认没有内核进程。
    func stopKernel(_ reply: @escaping (Bool) -> Void)

    /// 当前状态。运行中 → `(true, "<pid>")`；未运行 → `(false, nil)`。
    func kernelState(_ reply: @escaping (Bool, String?) -> Void)
}
