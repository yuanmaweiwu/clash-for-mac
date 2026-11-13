# 当前进度

> 更新：2026-11-13
> 保持短（建议 ≤80 行）；过长先压缩：过期已完成收成摘要，长文移 `plan/<topic>.md`。

## 目标

做一款 macOS 原生的 Clash 客户端：状态栏「控制中心」风格，v1 含 TUN，自带 mihomo 内核。

## 已完成

- [x] Agent 技能体系：`swiftui-app` / `architecture` / `plan` / `git` + 外部 `swiftui-pro`、`swiftui-expert-skill`（项目级 vendor）
- [x] `铁律 0`：技能只装项目级（`.agents/skills/`），禁止 `-g` 与用户级目录
- [x] 产品文档：`docs/00-PRODUCT.md`（定位、范围、术语、合规）
- [x] 架构文档：`docs/01-ARCHITECTURE.md`（helper + XPC 进程模型、配置流水线、API 面、代理还原）
- [x] 路线图：`docs/03-ROADMAP.md`（v0.1 → v1.0 + 风险登记）
- [x] ADR 0001–0004（自带内核 / macOS 15 / 手写 xcodeproj / TUN 与 helper 进 v1）

## 进行中

- [ ] UI 规范 `docs/02-UI-SPEC.md`（交给 designer 子代理撰写，风格=系统控制中心）
- [ ] 待用户确认：是否引入 `Yams`（`docs/adr/0005`）

## 下一步（按优先级）

1. 收 UI 规范 → 与用户过一遍视觉方向再定稿
2. 补齐技能（全部项目级）：`core-process`、`menubar-ui`、`system-proxy`、`build-release`
3. v0.1 骨架：`.xcodeproj`（App / Helper / Tests）+ `MenuBarExtra` 空面板 + helper 安装 + 内核启停 + `/version`
4. 探索 mihomo 二进制来源与签名方式（arm64/x86_64 通用包）

## 关键上下文（续作必读）

- 分支 `test`；remote 为内网 Gitea（`http://内网地址:3000/Clash/Clash.git`）
- 已定：macOS 15+ / Swift 6 / `.xcodeproj` 手写 / 自带 mihomo / v1 含 TUN / 设置 JSON + 配置 YAML
- 架构要点：**helper（root）是内核与系统写操作的唯一持有者**；App 只通过 XPC + mihomo HTTP/WS 通信
- 配置原则：用户 YAML 永不改写，注入只进 `runtime/`
- 构建命令已写入 `.agents/skills/swiftui-app/SKILL.md` §6（工程创建后需实测修正）
- 仓库目前仍无 Swift 代码

## 不要做

- 不要 `-g` 安装全局技能；不要引用用户级技能
- 不要擅自引入依赖（Yams 待确认；SwiftData / GRDB / Alamofire / 第三方 UI 库已否）
- 不要 push / 远程写（须用户当轮明确要求）
- 不要改写用户配置、不要在无快照情况下改系统代理
- 不要为「以后可能用」建空抽象、空目录
