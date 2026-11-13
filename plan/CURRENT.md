# 当前进度

> 更新：2026-11-13
> 保持短（建议 ≤80 行）；过长先压缩：过期已完成收成摘要，长文移 `plan/<topic>.md`。

## 目标

把 Clash（SwiftUI macOS 原生应用）的工程与 Agent 技能体系搭起来，再进入功能开发。

## 已完成

- [x] `git` 技能：自动本地 commit、中文 message、远程写闸门
- [x] `swiftui-app` 总入口：技术栈快照、分层总闸、子技能路由、全局铁律
- [x] `architecture` 技能：目录归属决策树、依赖禁令、新增 feature 流程、macOS 与 iOS 差异
- [x] `plan` 技能：`plan/CURRENT.md` 作为唯一进度源与上下文压缩落点
- [x] 项目级安装外部技能（`-a universal --copy`，vendor 进仓）：`swiftui-pro`、`swiftui-expert-skill`，版本锁在 `skills-lock.json`

## 进行中

- [ ] 等待用户拍板 5 项 TBD（见 `.agents/skills/swiftui-app/SKILL.md` §7）：
      内核客户端形态 / 最低 macOS 与 Xcode / 工程形态 / 持久化 / 分发方式

## 下一步（按优先级）

1. 第 2 批技能：`swift-style`、`code-review`
2. 第 3 批技能：`build-release`；按 TBD 结论决定是否加 `persistence` / `networking` / `core-process`
3. 工程初始化：Xcode 工程或 SPM 包 + 打包脚本（形态待定）

## 关键上下文（续作必读）

- 分支：`test`；remote 为内网 Gitea（`http://内网地址:3000/Clash/Clash.git`）
- 技能目录：`.agents/skills/`（**项目级**，用户明确不要全局技能）
- 当前仓库除技能与 AGENTS.md 外基本为空，尚未创建任何 Swift 代码
- 构建命令：待工程形态确定后写入 `.agents/skills/swiftui-app/SKILL.md` §6

## 不要做

- 不要 `-g` 安装全局技能
- 不要擅自引入依赖（SwiftData、Sparkle、第三方包）或选定架构
- 不要 push / 远程写（须用户当轮明确要求）
- 不要为「以后可能用」建空抽象、空目录
