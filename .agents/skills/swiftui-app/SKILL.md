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
| 并发 | Swift Concurrency（`async/await`、`actor`、`@MainActor`），Swift 6 严格检查 | 已定 |
| 日志 | `os.Logger`（`Logger(subsystem:category:)`） | 已定 |
| 最低 macOS | **macOS 15 Sequoia**（`docs/adr/0002`） | 已定 |
| Swift / Xcode | Swift 6 语言模式；Xcode 16+（以实机版本为准） | 已定 |
| 工程形态 | `.xcodeproj` 手写入库；target = App / Helper / Tests（`docs/adr/0003`） | 已定 |
| 内核 | 自带 `mihomo` 二进制（**仅 arm64**），helper 以子进程管理（`docs/adr/0001`、`0004`） | 已定 |
| 架构 | **arm64 only**（Apple Silicon）；不支持 x86_64，不做 universal | 已定 |
| 配置生成 | 解析原 YAML → 覆盖顶层键 → 写 `runtime/`，**绝不改写用户配置** | 已定 |
| 持久化 | 设置 JSON（`Codable` + 原子写）+ 配置 YAML 文件；**不用 SwiftData/GRDB** | 已定 |
| 第三方依赖 | 仅 `Yams`（YAML 解析）；Sparkle 到 v1.0 再接 | 已定 |
| 分发 | 自助下载 + 签名/公证 + Sparkle（App Store 不做） | 已定（细节 v1.0） |

**未确认项**：不要提前写依赖它的代码；`docs/00-PRODUCT.md`、`01-ARCHITECTURE.md`、`03-ROADMAP.md` 是本节的展开。

## 2. 目录总览（目标结构）

```
App/                   @main、场景与窗口（MenuBarExtra / 设置）、AppDelegate 桥接、AppEnvironment
Helper/                LaunchDaemon target（root）+ XPC 服务端
Shared/                App 与 Helper 共用：XPC 协议、DTO（必须 Sendable）
Features/<Feature>/    一个功能一个目录：<Feature>View / <Feature>Model / <Feature>Service
Core/
├── Models/            领域模型（优先 Sendable 值类型）
├── Services/          对外部世界的抽象：协议 + 各实现
├── Storage/           持久化实现
└── Utilities/         无 UI 的纯工具
UI/                    可复用控件、样式、Design Token、Preview 支持
Resources/             Assets、本地化、Info.plist、mihomo 二进制与 LICENSE
Tests/                 单元测试 / 集成测试
```

依赖方向单向：`Features → Core → Shared`；`Helper → Shared`（**禁止** import App 侧）；`UI` 只被 `Features` 使用。
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
| 阶段性 review / 合并前检查 | `code-review` + `swiftui-pro` | 外部技能已装：九维 review（废弃 API / 性能 / 无障碍 / 并发 / 卫生） |
| 写/改 View、状态、导航、动画、列表、macOS 场景 | `swiftui-expert-skill` |
| 视觉方向、材质、排版、动效的审美判断 | `apple-design` |
| 列表/绘制/刷新等性能问题 | `swiftui-performance` | 外部技能已装：API 正确性与现代写法 |
| 构建、签名、公证、CI、发布 | `build-release` | 计划中 |
| 续作 / 换电脑 / 进度交接 | `plan` | `plan/CURRENT.md` 是唯一进度源 |
| Git（自动本地提交） | `git` | 完成可验证改动自动本地 commit；未明确要求禁止远程写 |

未命中上表时**禁止**连读多个子技能「以防万一」。

外部技能是本仓库的**参考**，不是约定源：与本仓分层冲突时以 `architecture` / 本文件为准；它们假定较新 API（iOS 26 / Swift 6.2 语境），最低 macOS 未定前不要照搬版本相关写法。

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
10. **可访问性与深浅色**：必须支持 VoiceOver、Reduce Motion、深色模式；Dynamic Type 分场景——状态栏面板固定尺寸不缩放，设置窗口/日志等自由排版界面必须支持。不要写死颜色与像素（用 `docs/02-UI-SPEC.md` 的 token）。
11. **技能只装项目级**：一切 skill / agent 装进 `.agents/skills/`，永不加 `-g`；只能用全局的，先问用户（见 `AGENTS.md` 铁律 0）。

## 6. 常用命令

```bash
# 构建（Debug）
xcodebuild -project Clash.xcodeproj -scheme Clash -configuration Debug build

# 单元测试
xcodebuild -project Clash.xcodeproj -scheme Clash -destination 'platform=macOS' test

# 内核集成自检（待 v0.1 脚本落地）
./Scripts/kernel-smoke.sh
```

工程尚未创建前，以「方案可落地 + 文档自洽」为验收；工程落地后立即用上述命令实测并修正本节。

## 7. 已拍板的决定

| # | 决定 | 记录 |
|---|------|------|
| 1 | 自带 mihomo 二进制，helper 管理内核；v1 含 TUN | `docs/adr/0001`、`0004` |
| 2 | 最低 macOS 15 Sequoia | `docs/adr/0002` |
| 3 | 手写 `.xcodeproj` 入库（不用 XcodeGen/Tuist） | `docs/adr/0003` |
| 4 | 持久化 = 设置 JSON + 配置 YAML，不用 SwiftData/GRDB | `docs/01-ARCHITECTURE.md` |
| 5 | 依赖仅 Yams + Sparkle（v1.0） | `docs/adr/0005` |

界面语言：中文为主，全部文案走 `LocalizedStringKey`（String Catalog），预留英文。
仍有待确认：签名/公证/Sparkle 细节（v1.0 前）。
