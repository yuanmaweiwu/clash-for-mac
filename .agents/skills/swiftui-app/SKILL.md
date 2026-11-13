---
name: swiftui-app
description: "本仓库（Clash，SwiftUI macOS 原生应用）总入口与路由。凡新增/修改界面、状态、服务、持久化、构建配置，或用户要求「完整代码/单文件/从零写」时，必须先读本技能，再按路由表只加载对应子技能。涵盖：分层（View/Model/Service）、状态管理、macOS 场景与窗口、构建发布、代码审核、进度交接。触发词：SwiftUI、macOS、View、@Observable、状态、Feature、App、完整代码、单文件、从零。"
---

# Clash（SwiftUI macOS App）

项目定位：macOS 原生桌面应用，UI 用 SwiftUI，必要时 AppKit 桥接。

> 入口见 [`AGENTS.md`](../../../AGENTS.md)。按既有约定增删改；子技能按需加载，**禁止一次读完**。
> **写代码前 / 新开对话或续作**：先读 `plan/CURRENT.md`（`plan` 技能），再加载本技能。
> **工作区优先**：字面「完整代码/单文件」≠ 可拆分层或塞进一个 View。
> **需求不清 / 与实码或约定冲突**：先问用户，禁止自作主张选型或「顺手重构」。
> **改完一块可验证工作**：按 `git` 技能**自动本地 commit**（无需用户说提交）；未明确要求禁止 push。

## 1. 技术栈速查

| 领域 | 选型 | 状态 |
|------|------|------|
| UI | SwiftUI（iOS 习惯不要照搬，先看 `architecture` 的 macOS 差异） | 已定 |
| UI 兜底 | AppKit 桥接（`NSViewRepresentable` / `NSViewControllerRepresentable`） | 按需 |
| 状态 | `@Observable` + `@State`/`@Environment` | 已定 |
| 并发 | Swift Concurrency（`async/await`、`actor`、`@MainActor`） | 已定 |
| 日志 | `os.Logger`（`Logger(subsystem:category:)`） | 已定 |
| 最低 macOS | **待定**（决定可用 API 面） | TBD |
| Swift / Xcode | **待定** | TBD |
| 工程形态 | **待定**（`.xcodeproj` 或 SPM + 打包脚本） | TBD |
| 持久化 | **待定**（SwiftData / GRDB / 仅 YAML 文件） | TBD |
| 分发 | **待定**（签名 / 公证 / Sparkle） | TBD |

**TBD 项未定前**：不要引入依赖它的框架或 API；先问用户，再落地。

## 2. 目录总览（目标结构）

```
App/                   @main、场景与窗口、AppDelegate 桥接、依赖装配（AppEnvironment）
Features/<Feature>/    一个功能一个目录：<Feature>View / <Feature>Model / <Feature>Service
Core/
├── Models/            领域模型（优先 Sendable 值类型）
├── Services/          对外部世界的抽象：协议 + 各实现
├── Storage/           持久化实现
└── Utilities/         无 UI 的纯工具
UI/                    可复用控件、样式、Design Token、Preview 支持
Resources/             Assets、本地化、Info.plist 相关
Tests/                 单元测试 / UI 测试
```

工程形态确定前，目录只作**约定**，不急着建空目录。

## 3. 分层（跨任务总闸）

```
View → Model(视图状态) → Service(协议) → 实现(网络/进程/磁盘/系统)
```

- **View** 只声明界面与事件；不直接做 IO、不直接拿具体实现
- **Model** 持有该 feature 的状态与意图（`@Observable`），调 Service 协议
- **Service** 面向能力（协议）；实现可替换、可 mock
- 跨 feature 共享的放 `Core`，**不要**让 feature 之间互相 import View

细则（依赖禁令、代码放哪、feature 骨架）必读 [`architecture`](../architecture/SKILL.md)；**禁止只凭本段发挥**。

## 4. 子技能路由（按需加载）

| 任务 | 必读 | 说明 |
|------|------|------|
| 目录职责、代码放哪、新增 feature、跨 feature 复用 | `architecture` | 分层禁令 + feature 脚手架 |
| 命名 / 状态管理 / 并发 / 错误处理 / 日志 / 测试 | `swift-style` | 计划中，落地前按本文件铁律 |
| 阶段性 review / 合并前检查 | `code-review` | 计划中；可配合外部 `swiftui-pro` |
| 构建、签名、公证、CI、发布 | `build-release` | 计划中 |
| 续作 / 换电脑 / 进度交接 | `plan` | `plan/CURRENT.md` 是唯一进度源 |
| Git（自动本地提交） | `git` | 完成可验证改动自动本地 commit；未明确要求禁止远程写 |

未命中上表时**禁止**连读多个子技能「以防万一」。

## 5. 全局铁律

1. **单一状态源**：状态放在最靠近使用它的 `@Observable` 模型上；View 只读派生值，禁止各自缓存同一份数据。
2. **UI 状态 `@MainActor`**：`View`/模型默认主线程；跨 actor 传递必须 `Sendable`，禁止跨线程直接改 UI 状态。
3. **View 不做 IO**：网络、进程、磁盘、系统调用一律走 Service 协议；便于测试与替换。
4. **一个类型一个文件**；同 feature 内聚，文件名 = 类型名。
5. **不引入未确认依赖**：新库 / 新框架（含 SwiftData、Sparkle、第三方包）先问用户。
6. **不过度防御**：不做「不可能失败」的兜底；错误要么 `throw` 要么记日志，禁止 `try?` 静默吞掉。
7. **不擅自改架构**：不擅自引入 MVVM 之外的第三套结构、不加全局单例（除 `AppEnvironment`）。
8. **面向 macOS 而非 iOS**：窗口/菜单/快捷键/多窗口/拖放优先，别照搬 iPhone 的导航栈与全屏假设。
9. **冲突先问人**：需求模糊、与实码或本约定冲突时先问，禁止自作主张。
10. **可访问性与深浅色**：默认支持 Dynamic Type、VoiceOver、Reduce Motion、深色模式；不要写死颜色与像素。

## 6. 常用命令

构建方式随工程形态而定（TBD）。确定后在此固定，例如：

```bash
# .xcodeproj
xcodebuild -scheme Clash -configuration Debug build

# SPM
swift build
swift test
```

未确定前，改完以「能编译 + 手工跑通相关路径」为验收标准，并在 `plan/CURRENT.md` 记下实际命令。

## 7. 待用户拍板的决定

| # | 问题 | 影响 |
|---|------|------|
| 1 | 是否为 Clash 内核（mihomo）的图形客户端？需管进程 / 改 YAML / 设系统代理 / TUN helper？ | 决定是否新增 `core-process`、`system-proxy` 技能 |
| 2 | 最低 macOS 版本 + Xcode / Swift 版本 | 决定可用 SwiftUI API 与并发写法 |
| 3 | 工程形态：`.xcodeproj` 还是 SPM + 打包脚本 | 决定构建命令、CI 与 feature 目录归属 |
| 4 | 持久化：SwiftData / GRDB / 纯 YAML 文件 | 决定是否建 `persistence` 技能 |
| 5 | 分发：App Store / 自助下载 + 公证 / Sparkle 自动更新 | 决定 `build-release` 内容 |

答案落地后，删掉对应 TBD 行并更新本文件，避免约定长期空转。
