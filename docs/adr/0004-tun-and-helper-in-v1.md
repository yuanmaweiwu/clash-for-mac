# ADR-0004 · TUN 与 privileged helper 纳入 v1

- 状态：已接受（部分被 `adr/0007`、`adr/0008` 改写：v0.1 不引入 helper；系统代理不需要 root）
- 日期：2026-11-13
- 相关：`docs/01-ARCHITECTURE.md` §1 §6 §7

## 决定

v1 必须支持 TUN。因此从 v0.1 起就引入 root helper（`SMAppService.daemon` + XPC），内核由 helper 统一管理，而不是 App 直接 spawn。

## 理由

1. TUN 需要 root 创建 utun、改路由、接管 DNS；绕过不了的硬需求
2. ~~系统代理（`networksetup`）同样需要管理员权限~~ → 实测不需要 root，见 `adr/0008` 补充
3. 若先做「App 直接 spawn」再改 helper，等于把进程管理写两遍、状态机重写一遍
4. helper 是分发层面的关键风险（签名、公证、权限弹窗），越早暴露越好，晚发现代价更大

## 被否方案

| 方案 | 否决原因 |
|---|---|
| v1 只做系统代理 | 用户已明确要求 v1 含 TUN；后补会导致架构返工 |
| `AuthorizationExecuteWithPrivileges` 每次弹密码 | API 已废弃，体验差（每次开 TUN 都要输密码） |
| 让用户手动 `sudo` 起内核 | 体验不可接受，且无法自动化还原 |
| 只用 `SMJobBless` | 老机制仍可用但新系统推荐 `SMAppService`；统一走后者 |

## 后果

- 工程从第一天就有 Helper target 与 XPC 协议（`Shared/`）
- helper 安装/批准流程需要引导页与失败兜底（用户拒绝、批准后未生效）
- helper 只暴露白名单操作，不接受任意命令（安全边界见架构 §7）
- 必须先做「降权启动」：系统代理模式下内核以登录用户身份运行
- 开发期调试 helper 需要反复 `launchctl` 卸载/重装，准备脚本化，避免手工步骤
