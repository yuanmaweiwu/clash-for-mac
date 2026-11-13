# Agent Skills（Clash）

> 跨 IDE：根入口 [`../AGENTS.md`](../AGENTS.md)。技能只认 `.agents/skills/`，不绑某一编辑器。

```text
.agents/skills/
├── swiftui-app/        # 总入口：技术栈 + 路由表 + 全局铁律
├── architecture/       # 分层 / 目录归属 / 新增 feature
├── plan/               # 进度交接与上下文压缩（plan/CURRENT.md）
└── git/                # 提交 / 回退 / 远程安全约定
```

## 技能清单

| 技能 | 用途 | 何时加载 |
|------|------|----------|
| [`swiftui-app`](./skills/swiftui-app/SKILL.md) | 总入口：技术栈快照、分层总闸、子技能路由 | 任何 SwiftUI / macOS 改动前 |
| [`architecture`](./skills/architecture/SKILL.md) | 代码放哪层、依赖禁令、feature 骨架 | 新增/移动代码、跨 feature 复用 |
| [`plan`](./skills/plan/SKILL.md) | 进度快照与上下文压缩 | 新开对话、续作、阶段收尾 |
| [`git`](./skills/git/SKILL.md) | 自动本地 commit、中文 message、远程闸门 | 改完收尾、大改前、回退、push |

## 计划中

`swift-style`（写法约定）、`code-review`（分级审核）、`build-release`（构建/签名/公证/CI）；
`persistence` / `networking` / `core-process` 视项目形态决定是否新增。

## 外部技能（项目级安装）

`npx skills add` **默认装项目级**（`-g` 才是全局，本仓库不要用）：

```bash
npx skills add twostraws/swiftui-agent-skill --skill swiftui-pro
npx skills add avdlee/swiftui-agent-skill --skill swiftui-expert-skill
```

## 冲突优先级

1. 仓库实码
2. 本目录技能
3. 外部 / 通用技能
