# Agent 入口（Clash）

> **跨 IDE 通用**：本文件 + `.agents/skills/` 是唯一 Agent 约定源。
> 不要依赖某一编辑器专有目录才能遵守约定。

## 技能

| 任务 | 技能 |
|------|------|
| Git：提交 / 检查点 / 回退 / push | [`git`](.agents/skills/git/SKILL.md) |

清单与结构见 [`.agents/README.md`](.agents/README.md)。

## 铁律

1. **完成一小段可验证改动 → 自动本地 commit**，用户不必再说「提交」；不要只改一半就提交。
2. **远程写仅凭显式授权**：push / 删远程分支 / 删远程仓只在用户当轮明确要求时执行；「提交」「检查点」「同步一下」都不算授权。
3. **禁止提交密钥**：`.env`、真实密码 / Token 一律排除。
4. **一个意图一条 commit**：message 用中文，动词白话 + 反引号包对象（细则见 `git` 技能）。
5. **冲突先问人**：约定与实码冲突、操作不可逆（`reset --hard`、`clean -fd`、force push）时先确认。
