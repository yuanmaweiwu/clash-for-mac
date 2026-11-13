# Agent 入口（Clash）

> **跨 IDE 通用**：本文件 + `.agents/skills/` 是唯一 Agent 约定源。
> 不要依赖某一编辑器专有目录才能遵守约定。

本仓库是 **macOS 原生应用**（SwiftUI），项目名 Clash。

## 写代码前（强制）

修改任何 Swift / 工程配置前：

1. 读 [`plan/CURRENT.md`](plan/CURRENT.md)（`plan` 技能）
2. 加载 [`swiftui-app`](.agents/skills/swiftui-app/SKILL.md)（总入口）
3. 按任务路由**只加载**对应子技能（禁止一次读完）

禁止：不读 skill 本体就开始写。

## 技能

| 任务 | 技能 |
|------|------|
| 总入口 / 路由 / 技术栈 / 铁律 | [`swiftui-app`](.agents/skills/swiftui-app/SKILL.md) |
| 目录归属 / 分层 / 新增 feature | [`architecture`](.agents/skills/architecture/SKILL.md) |
| 进度交接 / 续作 / 上下文压缩 | [`plan`](.agents/skills/plan/SKILL.md) |
| Git：提交 / 检查点 / 回退 / push | [`git`](.agents/skills/git/SKILL.md) |

清单与结构见 [`.agents/README.md`](.agents/README.md)。

## 铁律

1. **完成一小段可验证改动 → 自动本地 commit**，用户不必再说「提交」；不要只改一半就提交。
2. **远程写仅凭显式授权**：push / 删远程分支 / 删远程仓只在用户当轮明确要求时执行；「提交」「检查点」「同步一下」都不算授权。
3. **技能一律项目级**：装到本仓库 `.agents/skills/`，不加 `-g`。
4. **禁止提交密钥**：`.env`、真实密码 / Token 一律排除。
5. **一个意图一条 commit**：message 用中文，动词白话 + 反引号包对象（细则见 `git` 技能）。
6. **冲突先问人**：需求模糊、与实码或本约定冲突、操作不可逆（`reset --hard`、`clean -fd`、force push）时先确认。
7. **不擅自选型**：新依赖 / 新框架（SwiftData、Sparkle、第三方包）与工程形态变更，先问用户。
