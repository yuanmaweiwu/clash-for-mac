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

## 被否方案

| 方案 | 否决原因 |
|---|---|
| 每次用 `sudo` 起内核 | 体验差且无法自动化还原；错误处理不可控 |
| 让用户手动装 LaunchDaemon | 步骤多、易错，且无法版本对齐 |
| 只做用户态、放弃 TUN/系统代理 | 与产品定位冲突（v1 必含 TUN） |
