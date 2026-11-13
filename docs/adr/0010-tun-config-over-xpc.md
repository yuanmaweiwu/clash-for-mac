# ADR-0010 · TUN 的运行配置由 App 生成、经 XPC 送正文

- 状态：已接受
- 日期：2026-11-13
- 相关：`adr/0004`（TUN 与 helper 进 v1）、`adr/0007`（v0.1 App 直启内核）、`adr/0008`（helper 安装）

## 背景

TUN 模式下内核以 root 启动，配置必须落在 root 目录（`/Library/Application Support/ClashHelper/runtime.yaml`）。
需要回答一个绕不开的问题：**这份 root 配置由谁生成、怎么送到位？**

候选：

| 方案 | 问题 |
|---|---|
| helper 读 App 的 `runtime/` 目录 | 等于给 root 一个「按调用方路径读文件」的入口；App 目录可被普通用户改写，root 内核会加载被篡改的配置 |
| helper 自己跑一遍 `RuntimeConfigBuilder` | 配置生成逻辑（订阅合并、注入、安全默认值）要在两个 target 里各写一份，必然走样 |
| XPC 传路径 | 同上第一条，且路径参数本身破坏「不接受任意路径」的白名单原则 |
| **XPC 传正文** | 需要限制体积、校验格式，但语义最干净 |

## 决定

1. **App 生成正文**：`RuntimeConfigBuilder.yaml(from:injected:)` 只产出字符串，不落盘。
2. **正文经 XPC 送达**：`applyRuntimeConfig(_ bytes: Data)`，helper 侧：
   - 拒绝空正文 / 超过 5 MB / 非 UTF-8
   - `Yams.load` 解析，顶层必须是映射（不合法直接拒，不保留上一份）
   - 原子写 `HelperLayout.runtimeConfigPath`（临时文件 0600 → `rename(2)` → 目标 0600 root:wheel）
   - **不启动内核**：写配置与启动拆成两步，失败时不必先起再回滚
3. **端口与 secret 由 App 生成**，随正文送达。App 因此已经知道 API 端点，不需要再新增
   `runtimeInfo` 之类的反向查询接口——接口面越小越好。
4. **路径永不过 XPC**：落盘位置固定由 `HelperLayout` 推导，和内核二进制路径同一原则。

## 后果

- helper 需要链接 Yams（与 App 同一个包，版本一致；helper 体积 +约 200 KB）
- 协议升到 v2：旧 helper 会被 `ping` 判定为版本不符 → 提示「组件需要更新」并覆盖安装
- TUN 内核的控制器端点由 `TunService` 交给 `KernelService.adoptExternalKernel`，
  策略组 / 流量 / 连接 / 日志四处客户端零改动即可复用
- 单次 XPC 上限 5 MB：正常订阅配置在 100 KB 量级，余量充足；上限存在只是防止误传巨型文件
