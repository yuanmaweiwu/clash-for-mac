---
name: architecture
description: "本仓库（SwiftUI macOS App）的项目结构、分层职责、依赖流向与 feature 组织方式。判断代码放哪一层、新增 feature、跨 feature 复用、视图与状态/服务边界、依赖注入与 Preview 时使用。触发词：项目结构、目录结构、分层、依赖流向、新增 feature、新功能、MVVM、状态管理、依赖注入、Environment、Preview、跨模块。"
---

# 项目结构与分层

> 先读总入口 [`swiftui-app`](../swiftui-app/SKILL.md)。写法细节见 `swift-style`。
> 工程形态（`.xcodeproj` / SPM）**尚未确定**：本文件定义**目标分层与归属**，目录名可按工程形态调整，但层级与依赖方向不变。

## 1. 结构速查

```
App/                   组合根：@main、Scene/Window、AppDelegate 桥接、AppEnvironment
Features/<Feature>/    功能竖切：View + Model + （可选）该 feature 专属 Service/子视图
Core/Models/           领域模型（跨 feature 共享，优先 Sendable 值类型）
Core/Services/         能力协议 + 默认实现（网络 / 进程 / 磁盘 / 系统设置）
Core/Storage/          持久化实现（复用 Core/Models）
UI/                    可复用控件、样式、Design Token、Preview 辅助
Resources/             Assets、本地化、Info.plist 相关
Tests/                 单元 / UI 测试
```

一个 feature 的典型文件：

| 文件 | 职责 |
|------|------|
| `<Feature>View.swift` | 界面声明 + 事件转发，不写 IO |
| `<Feature>Model.swift` | `@Observable`，持有状态与意图，调 Service 协议 |
| `<Feature>Service.swift` | 仅当能力只服务于本 feature 时才放这里；否则提回 `Core/Services` |

## 2. 依赖方向（硬性）

```
View → Model → Service(协议) ← 实现(Core/Services|Storage)
```

| 层 | 允许 | 禁止（出现即违规） |
|----|------|--------------------|
| **View** | 读 Model 状态、发意图、`@Environment` 取依赖、组合子视图 | 网络/进程/磁盘调用、`FileManager.default` 直接读业务数据、持有具体 Service 实现类型 |
| **Model** | `@Observable` 状态、调 Service 协议、`Task` 编排、错误→可展示状态 | `import SwiftUI` 里的视图类型、直接 `URLSession`、直接读 `UserDefaults` 结构 |
| **Service 协议** | 只描述能力与数据契约 | 出现 UI 类型（`Color`/`View`/`@MainActor` 的展示模型） |
| **实现** | 系统框架、第三方库、IO | 反向依赖 `Features/*` |
| **Core** | 依赖平台框架 | import `Features/*`（Core 必须比 feature 更低层） |

跨 feature 规则：

1. feature 之间**禁止**互相 import `View`。
2. 共享能力 → 上提 `Core/Services`；共享展示组件 → 上提 `UI/`。
3. 共享状态确有必要（如全局连接状态）→ 放 `App` 层的 environment 对象，由组合根注入，**不要**用全局单例。

细则与反例必读 [references/layers.md](references/layers.md)。

## 3. 新增 feature（强制流程）

1. 先确认归属：是**新 feature** 还是已有 feature 的子视图？是共享能力还是专属能力？
2. 建 `Features/<Feature>/`，只放该功能需要的文件；**不建空文件、不提前抽象**。
3. 能力接口放 `Core/Services/<能力>Service.swift`（协议），默认实现放同目录或 `Core/Storage/`。
4. 组合根（`App/`）负责把实现注入 environment；feature 内不 `init` 具体实现。
5. 涉及跨 feature 状态 → 先问用户，再决定放 `App` 层还是上提 `Core`。
6. 收尾：编译 + 跑通路径 + 更新 `plan/CURRENT.md` + 自动本地 commit（见 `git`）。

参考骨架（`@Observable` 需 macOS 14+，最低版本未定时先确认）：

```swift
// Features/Settings/SettingsModel.swift
import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {
    private let store: SettingsStoring
    private(set) var isLoading = false
    var errorMessage: String?

    init(store: SettingsStoring) {
        self.store = store
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { try await store.load() } catch { errorMessage = error.localizedDescription }
    }
}
```

```swift
// Features/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @State private var model: SettingsModel
    @Environment(\.settingsStore) private var store   // 或由组合根注入

    var body: some View {
        Form { /* 只读 model 状态、发意图 */ }
            .task { await model.load() }
    }
}
```

## 4. 依赖注入与 Preview

- 组合根在 `App/` 装配（构造 environment 或 `@Environment` 自定义 key）。
- 协议 + 轻量假实现（in-memory）优先，**不要**为测试引入 DI 框架。
- 每个 View 至少一个 Preview，走假实现，不连真实系统。

## 5. macOS 与 iOS 的差异（易错点）

| 主题 | macOS 做法 |
|------|-----------|
| 导航 | 优先 `NavigationSplitView` / 多窗口 `WindowGroup`，不要照抄 `TabView` 手机栈 |
| 菜单与快捷键 | `CommandGroup`、`.keyboardShortcut`；菜单项要反映可用状态 |
| 常驻 | 菜单栏用 `MenuBarExtra`；后台常驻需明确窗口关闭语义（`.windowResizability`、`applicationShouldTerminateAfterLastWindowClosed`） |
| 输入 | 悬停 `.onHover`、右键 `.contextMenu`、拖放 `.onDrop`，桌面上是**必做**不是加分 |
| 窗口状态 | 记住尺寸/位置（`@SceneStorage` / `NSWindow` 恢复），多窗口下状态不要串 |
| 沙盒 | 文件访问走用户选择或安全书签；不要假设能随便读磁盘 |
| 尺寸 | 不要写死像素；用 `.frame(minWidth:idealWidth:)` + SF Symbols + 系统间距 |

## 6. 自检

- [ ] 新代码放在正确层（View / Model / Service / Core），没有反向依赖
- [ ] View 内无 IO，无具体实现类型
- [ ] 共享能力已上提 `Core`，没有 feature 互引 `View`
- [ ] 没有为「以后可能用」而建的抽象与空文件
- [ ] macOS 交互（菜单 / 快捷键 / 悬停 / 窗口状态）已考虑
- [ ] `plan/CURRENT.md` 已更新，改动已本地 commit
