# Agent Skills（Clash）

> 跨 IDE：根入口 [`../AGENTS.md`](../AGENTS.md)。技能只认 `.agents/skills/`，不绑某一编辑器。

```text
.agents/skills/
└── git/            # 提交 / 回退 / 远程安全约定（SKILL.md + references/）
```

## 技能清单

| 技能 | 用途 | 何时加载 |
|------|------|----------|
| [`git`](./skills/git/SKILL.md) | 自动本地 commit、中文 message、远程写闸门 | 改完收尾、大改前、回退、push |

## 冲突优先级

1. 仓库实码
2. 本目录技能
3. 外部 / 通用技能
