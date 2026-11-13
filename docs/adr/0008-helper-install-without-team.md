# ADR-0008 · 无开发者账号下的特权 helper 安装方式

- 状态：已接受
- 日期：2026-11-13
- 相关：`adr/0004`（TUN 与 helper 进 v1）、`adr/0007`（v0.1 App 直启内核）

## 背景

用户明确：**不使用 Apple 开发者账号、不上架 App Store，只自用**；愿意在「系统设置 → 隐私与安全性」里手动允许应用运行。

这意味着：

- 没有 Developer ID / Apple Development 证书，`SMAppService.daemon` 与 `SMJobBless` 都**无法注册**（两者都要求有效签名）
- 但系统代理（`networksetup`）与 TUN（创建 utun、改路由）**必须 root**，绕不过去

## 决定

1. **签名**：ad-hoc（`codesign -s -`），关闭 Hardened Runtime，不做公证。Gatekeeper 拦截由用户按提示在系统设置里「仍要打开」。
2. **helper 安装**：不用 `SMAppService`，改为**一次性管理员授权安装 LaunchDaemon**：
   - 用户首次开启 TUN / 系统代理时，App 通过 `osascript … with administrator privileges` 弹一次系统密码框
   - 该脚本以 root 做三件事：拷 helper 到 `/Library/PrivilegedHelperTools/com.clash.helper`、写 `/Library/LaunchDaemons/com.clash.helper.plist`（`MachServices`、`KeepAlive`、`RunAtLoad`）、`launchctl bootstrap system <plist>`
   - 卸载时逆操作（`launchctl bootout` → 删 plist → 删二进制），同样一次授权
3. **XPC 连接校验**：不用签名校验（ad-hoc 无 team id）。用 `audit_token` 取客户端 pid → 反查其可执行路径，必须等于当前 App 的 `Bundle.main.bundlePath`，否则拒绝连接。
4. **版本升级**：helper 二进制内嵌版本号；App 启动时比对，不一致则在用户下次授权时覆盖安装（覆盖安装必然要再输一次密码，接受）。
5. **安全边界不变**：helper 只暴露白名单方法（`startKernel` / `stopKernel` / `setSystemProxy` / `restoreSystemProxy` / `state`），**不接受任意命令、不收任意路径**；内核与 runtime 配置的路径由 helper 自己从固定目录推导。

## 理由

- 自用场景下，一次管理员密码交互的代价，远低于申请证书 + 公证的流程成本
- 手动安装 LaunchDaemon 是不上架工具的标准做法，launchd 的 `KeepAlive` 还顺带解决了 helper 崩溃自恢复
- 保留 `KernelService` 协议：将来若有证书，只需把安装方式换回 `SMAppService`，业务层零改动

## 影响

| 项 | 结果 |
|---|---|
| 首次使用 TUN/代理 | 弹一次管理员密码 + 系统设置里允许应用 |
| helper 升级 | 需要再授权一次 |
| Gatekeeper | 每次换构建可能都要在「隐私与安全性」点允许（自用可接受） |
| 分发 | 不做 DMG 自动更新签名校验；Sparkle 需要签名，**v1.0 的自动更新取消或改为手动下载** |
| 安全性 | 比 SMAppService 略弱（无签名链校验），用路径 + audit token 校验兜底 |

## 补充 · 系统代理不需要 root（2026-11-13 实测）

在本机（macOS 15.7，管理员账号）实测：

| 命令 | 结果 |
|---|---|
| `networksetup -setwebproxy "Thunderbolt Bridge" 127.0.0.1 18080` | exit 0，`get` 读回 `Enabled: Yes` |
| `networksetup -setwebproxystate … off` | exit 0，读回 `Enabled: No` |
| `networksetup -setproxybypassdomains … 127.0.0.1` | exit 0，读回生效 |

结论：**系统代理在 App 进程内直接改即可，helper 不再为它存在**。helper 的唯一职责收窄为 **TUN**（创建 utun、改路由、接管 DNS）。

因此排期变为：v0.2 系统代理（无 helper）→ v0.4 TUN（此时才需要管理员授权安装 helper）。

## 被否方案

| 方案 | 否决原因 |
|---|---|
| 每次用 `sudo` 起内核 | 体验差且无法自动化还原；错误处理不可控 |
| 让用户手动装 LaunchDaemon | 步骤多、易错，且无法版本对齐 |
| 只做用户态、放弃 TUN/系统代理 | 与产品定位冲突（v1 必含 TUN） |

## 补充 · 落地实现（2026-11-13，只做「安装 + XPC 骨架」，未接 TUN）

### 协议 v1（`Shared/KernelHelperProtocol.swift`）

| 方法 | 说明 |
|---|---|
| `ping(reply: (String) -> Void)` | 返回 `HelperVersion`（当前 `1`）；App 不等 → 提示「组件需要更新」 |
| `startKernel(reply: (Bool, String?) -> Void)` | 以 root `posix_spawn` 式启动 `/Library/PrivilegedHelperTools/mihomo`；成功回 `pid=<n>` |
| `stopKernel(reply: (Bool) -> Void)` | `SIGTERM` → 3s → `SIGKILL`；`true` = 已确认退出 |
| `kernelState(reply: (Bool, String?) -> Void)` | `(true, "<pid>")` / `(false, nil)` |

**没有参数就没有注入面**：二进制路径 `/Library/PrivilegedHelperTools/mihomo`、配置路径
`/Library/Application Support/ClashHelper/runtime.yaml`、日志 `/Library/Application Support/ClashHelper/kernel.log`（0600 root）
全部由 helper 从 `HelperLayout` 推导，App 无法指定。以后加方法也只能是「动作 + 固定路径」，不是「命令 + 参数」。

### 客户端校验：`processIdentifier` 而不是 `auditToken`

原决定写的是「取 `auditToken` 的 pid」。落地时核对 macOS 26 SDK：`NSXPCConnection` **没有公开
`auditToken`**，公开的只有 `auditSessionIdentifier` / `processIdentifier` / `effectiveUserIdentifier` /
`effectiveGroupIdentifier`，且头文件明确写着「may be used by the listener delegate to accept or reject
connections」——正是我们要的场景。因此改为：

1. `shouldAcceptNewConnection` 里取 `connection.processIdentifier`（内核填写，客户端伪造不了）
2. `proc_pidpath` 反查可执行路径，规范化后必须 `hasSuffix("/Clash.app/Contents/MacOS/Clash")`
3. 拒绝 `effectiveUserIdentifier == 0`（App 永远以普通用户运行）
4. 不通过 → `invalidate()` + 返回 `false`

不采用私有 KVC `auditToken`：能拿到真 token，但依赖未公开键，系统一改就静默失效。

### 弱校验的边界（自用可接受）

| 能防 | 防不住 |
|---|---|
| 同机其他普通程序「顺手」连上 mach service | 把自己二进制放到 `…/Clash.app/Contents/MacOS/Clash` 的恶意程序 |
| 其他用户会话里的程序（`effectiveUserIdentifier` 不同/路径不符） | pid 复用竞态（进程退出后 pid 被占，窗口极窄） |
| 用 root 上下文冒充（直接拒 uid 0） | 已经拿到 root 的人（那时 helper 本身也不再是边界） |

根本原因是 ad-hoc 签名没有 team id，无法用 `setCodeSigningRequirement:`（macOS 13+）写签名要求。
**将来一旦有证书**：加一行 `connection.setCodeSigningRequirement(...)` 或换回 `SMAppService`，
上层 `HelperClient` / 调用方零改动。

### 安装脚本的两个实测坑

1. **必须先 `launchctl bootout` 再覆盖二进制**：覆盖一个仍被 mihomo 打开的二进制会 `ETXTBSY`，
   所以脚本顺序是「建目录 → bootout → cp → 写 plist → bootstrap」，不是「cp → … → bootout」。
2. **脚本文本不塞进 AppleScript 字符串**：两层引号转义后无法审阅。改为写 0700 临时文件，
   `do shell script "/bin/sh '<path>'" with administrator privileges`；脚本内部一律单引号包路径。

`plutil -lint` 在脚本里跑一次再 `bootstrap`，避免写坏 plist 时 launchd 报一句无用的 `Bootstrap failed`。

### 本轮没做（下一轮 TUN 接入前要定）

- `runtime.yaml` 还没有生产者：`/Library/Application Support/ClashHelper` 归 root:wheel，App 写不进去，
  而 XPC 又不接受路径。要么 helper 增加「接收配置正文（非路径）」的方法，要么由 helper 用固定规则
  从 App 已有目录推导配置（需重新审视「root 读用户可写文件」的风险）。
- 内核降权（系统代理模式）未做：v1 只 root 起 TUN；`posix_spawnattr_setuid_np` 那条路留给下一轮。
- helper 崩溃重启后的孤儿内核（内存里的 pid 丢失）未做路径级回收，`core-process` §2 的 reaper 目前只在 App 侧且比的是包内路径。
