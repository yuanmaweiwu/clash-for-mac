# ADR-0007 · v0.1 暂由 App 直接启动内核（helper 延后）

- 状态：已接受（临时方案，helper 安装方式见 `adr/0008`）
- 日期：2026-11-13
- 相关：`adr/0004-tun-and-helper-in-v1.md`

## 背景

本机 `security find-identity -v -p codesigning` 返回 **0 个有效身份**。`SMAppService.daemon` 注册 root LaunchDaemon 需要有效签名，ad-hoc 签名在多数 macOS 版本上无法完成注册与授权交互。若坚持 v0.1 就接 helper，会把「能跑起来的应用」推迟到拿到开发者证书之后。

## 决定

- **v0.1**：内核由 **App 以登录用户身份 `Process` 启动**（无 root、无 TUN、无系统代理）。用于打通：内置二进制 → 生成最小 runtime 配置 → 启动 → `/version` → 停止。
- 代码仍按 `docs/01-ARCHITECTURE.md` 的分层写：`KernelService` 协议 + `LocalKernelRunner` 实现；所有状态机、错误分类、端口分配、secret 生成与 helper 方案一致。
- **helper 的目标不变**：一旦具备签名身份，新增 `HelperProcessRunner` 实现 + Helper target，只替换 `KernelService` 的实现，不动上层。

## 影响

| 项 | v0.1 | 具备签名后 |
|---|---|---|
| 内核进程 owner | App | helper |
| TUN | 不可用（不做入口或置灰并说明） | 可用 |
| 系统代理 | 不可用（v0.2 依赖 root） | 可用 |
| 崩溃后内核回收 | App 退出即停（更简单，无残留） | helper 负责 |

- v0.2 的系统代理、v0.4 的 TUN 都**必须先有 helper**；因此拿到证书是 v0.2 的前置条件，不是可选项。
- 期间 UI 上凡涉及 TUN / 系统代理的开关：显示为不可用并给出「需要管理员组件（待签名）」的原因，不做假开关。

## 触发回退的条件

- **不再等证书**：用户确认不使用开发者账号、不上架（见 `adr/0008`），helper 改由「一次性管理员授权安装 LaunchDaemon」落地
- v0.1 先用 `LocalKernelRunner` 把内核链路跑通，作为 Debug 兜底；helper 在 v0.2（系统代理）之前接入
