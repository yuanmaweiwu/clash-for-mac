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
- [x] ADR 0001–0005（自带内核 / macOS 15 / 手写 xcodeproj / TUN 与 helper 进 v1 / Yams 定案）
- [x] 依赖定案：`Yams` 为唯一第三方解析库，Sparkle 到 v1.0；界面中文为主、预留本地化
- [x] 技能补齐：`core-process`（内核/API/TUN）、`menubar-ui`（状态栏/浮层）
- [x] UI 规范 `docs/02-UI-SPEC.md`：Token / 340×640 面板结构 / 组件四态 / 7 处动效 / 无障碍 / 空错态
  - 已裁定冲突：状态栏图标语义统一为「是否接管流量」；Dynamic Type 分场景（面板固定、设置窗口支持）
- [x] 内核获取：`Scripts/fetch-kernel.sh` 取上游 latest arm64；已实测 v1.19.34（arm64，57MB）

## 进行中

- [ ] UI 规范待用户过目（`docs/02-UI-SPEC.md` 已产出 400 行，已自查并消解与技能的口径冲突）

## 下一步（按优先级）

1. 用户确认视觉方向 → 定稿 UI 规范
2. 补齐技能（全部项目级）：`system-proxy`、`swift-style`、`build-release`
3. v0.1 骨架：`.xcodeproj`（App / Helper / Tests）+ `MenuBarExtra` 空面板 + helper 安装 + 内核启停 + `/version`
4. 内核签名与 helper spawn 校验方案（v0.1 内落地）

## 关键上下文（续作必读）

- 分支 `test`；remote 为内网 Gitea（`http://内网地址:3000/Clash/Clash.git`）
- 已定：macOS 15+ / **仅 arm64** / Swift 6 / `.xcodeproj` 手写 / 自带 mihomo / v1 含 TUN / 设置 JSON + 配置 YAML
- 架构要点：**helper（root）是内核与系统写操作的唯一持有者**；App 只通过 XPC + mihomo HTTP/WS 通信
- 配置原则：用户 YAML 永不改写，注入只进 `runtime/`
- 构建命令已写入 `.agents/skills/swiftui-app/SKILL.md` §6（工程创建后需实测修正）
- 仓库目前仍无 Swift 代码

## 不要做

- 不要 `-g` 安装全局技能；不要引用用户级技能
- 不要擅自引入依赖（仅 Yams 已批；SwiftData / GRDB / Alamofire / 第三方 UI 库已否）
- 不要 push / 远程写（须用户当轮明确要求）
- 不要改写用户配置、不要在无快照情况下改系统代理
- 不要为「以后可能用」建空抽象、空目录
