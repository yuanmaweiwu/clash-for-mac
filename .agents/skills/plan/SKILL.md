---
name: plan
description: "本仓库 AI 编程进度目录 plan/：跨机器续作、断线重开、会话交接，以及上下文压缩（防过载）。新开对话、继续/换电脑、完成阶段性改动、换话题、加载重技能前、或用户要求压缩/记进度时读写 plan/。触发词：plan、进度、继续、断点、续作、换电脑、换机、会话交接、CURRENT、压缩上下文、上下文过载、checkpoint。"
---

# AI 编程进度（plan/）

仓库根目录 `plan/` 存放**可提交的 AI 协作进度**，并作为**上下文压缩落点**。

> 写代码仍按各子技能；**进度只认 `plan/`**，不要只写在聊天里。
> 长细则：**读取** [references/context-compress.md](references/context-compress.md)。

## 1. 目录约定

```
plan/
├── README.md      # 给人看的说明（勿当进度源）
├── CURRENT.md     # 唯一「当前状态」入口（压缩后的权威快照）
└── *.md           # 可选专题笔记（长文放这，CURRENT 只留指针）
```

- **权威文件**：`plan/CURRENT.md`。
- 与 `CURRENT.md` 冲突时以它为准。
- `plan/` **应进 git**；勿塞密钥、真实密码、本地绝对路径隐私。
- **`CURRENT.md` 宜短**（建议 ≤80 行）；过长先压缩再续作。

## 2. 何时必须读 / 写 / 压缩

| 时机 | 动作 |
|------|------|
| **新开对话 / 继续 / 换电脑** | **先读** `CURRENT.md`；用它接续，**禁止**复述旧聊天 |
| **完成一块可交付改动** | **更新** `CURRENT.md`（= 一次压缩 checkpoint） |
| **换话题 / 新开大任务** | 先写完当前 `CURRENT`，再开新目标 |
| **加载多个重技能 / 大 review 前** | 先更新 `CURRENT`，再按路由按需读 |
| **试错结束 / 方案已否决** | 只把结论与「不要做」写入 plan |
| **用户要求记进度 / 压缩 / 收工** | 立即更新 `CURRENT` |
| **发现与实码不符** | 以实码为准改 `CURRENT` |
| **需求模糊 / 与实码或拟写方案冲突** | **先问用户**，禁止自作主张改代码后再补问 |

禁止：只在回复里说「下次继续 xxx」却不写进 `plan/`。

压缩步骤与取舍：**读取** [references/context-compress.md](references/context-compress.md)。

## 3. CURRENT.md 格式

**复制** [assets/CURRENT.template.md](assets/CURRENT.template.md)（勿整份灌进对话）；保持短、可扫、用清单。

## 4. 没有 CURRENT.md 时

1. 扫一眼仓库（`README.md`、`.agents/skills/swiftui-app/SKILL.md`、git status）
2. 从 assets 模板新建 `plan/CURRENT.md`
3. 再开始改代码

## 5. 与其它技能的关系

- 写 SwiftUI / 状态 / 服务 → 仍按 `swiftui-app` 路由加载子技能。
- `plan/` **不替代** skills；skills 是约定，`plan/` 是进度快照与压缩落点。

## 6. 自检

续作开始前：已读 `CURRENT.md`，下一步与用户诉求对齐。
收工 / 压缩后：`已完成` / `下一步` 已更新；未把 `CURRENT` 全文贴回聊天；无真实密钥。
