# Agent Skills（Clash）

> 跨 IDE：根入口 [`../AGENTS.md`](../AGENTS.md)。技能只认 `.agents/skills/`，不绑某一编辑器。

```text
.agents/skills/
├── swiftui-app/            # 总入口：技术栈 + 路由表 + 全局铁律
├── architecture/           # 分层 / 目录归属 / 新增 feature
├── plan/                   # 进度交接与上下文压缩（plan/CURRENT.md）
├── git/                    # 提交 / 回退 / 远程安全约定
├── swiftui-pro/            # 外部：SwiftUI 代码 review（Paul Hudson）
└── swiftui-expert-skill/   # 外部：SwiftUI 现代 API / macOS 场景（Antoine van der Lee）
```

## 技能清单

| 技能 | 来源 | 用途 | 何时加载 |
|------|------|------|----------|
| [`swiftui-app`](./skills/swiftui-app/SKILL.md) | 本仓 | 总入口：技术栈快照、分层总闸、子技能路由 | 任何 SwiftUI / macOS 改动前 |
| [`architecture`](./skills/architecture/SKILL.md) | 本仓 | 代码放哪层、依赖禁令、feature 骨架 | 新增/移动代码、跨 feature 复用 |
| [`plan`](./skills/plan/SKILL.md) | 本仓 | 进度快照与上下文压缩 | 新开对话、续作、阶段收尾 |
| [`git`](./skills/git/SKILL.md) | 本仓 | 自动本地 commit、中文 message、远程闸门 | 改完收尾、大改前、回退、push |
| [`swiftui-pro`](./skills/swiftui-pro/SKILL.md) | twostraws | 九维 review：废弃 API / 性能 / 数据流 / 无障碍 / 并发 | review、合并前检查 |
| [`swiftui-expert-skill`](./skills/swiftui-expert-skill/SKILL.md) | AvdLee | 现代 API、状态流、动画、列表、macOS scenes | 写/改 View 与状态时查证 |

## 计划中

`swift-style`（写法约定）、`code-review`（分级审核）、`build-release`（构建/签名/公证/CI）；
`persistence` / `networking` / `core-process` 视项目形态决定是否新增。

## 外部技能的维护

已 vendor 进仓库（`installMode: copy`），由根目录 [`skills-lock.json`](../skills-lock.json) 锁定版本：

```bash
npx skills update          # 更新项目级技能（勿加 -g）
npx skills ls              # 查看项目级已装技能
```

安装 / 重装时务必指定 `-a universal`（即 `.agents/skills/`）+ `--copy`，**不要**加 `-g`：

```bash
npx skills add twostraws/swiftui-agent-skill --skill swiftui-pro -a universal --copy
npx skills add avdlee/swiftui-agent-skill --skill swiftui-expert-skill -a universal --copy
```

外部技能是**参考**不是约定源：与本仓分层冲突时以 `architecture` 为准。

## 冲突优先级

1. 仓库实码
2. 本目录技能
3. 外部 / 通用技能
