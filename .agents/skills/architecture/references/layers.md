# 分层职责、反例与归属决策

> 总入口 [`swiftui-app`](../../swiftui-app/SKILL.md) → 主文件 [SKILL.md](../SKILL.md)。本文件只放「放哪、别放哪」。

## 1. 代码放哪：决策树

```
这段代码是什么？
├─ 界面声明 / 修饰符          → Features/<F>/View.swift（可复用才上提 UI/）
├─ 该 feature 的状态与意图     → Features/<F>/Model.swift（@Observable）
├─ 与外部世界打交道（网络/进程/磁盘/系统设置）
│   ├─ 只服务一个 feature      → Features/<F>/<Capability>Service.swift
│   └─ 多个 feature / 全局     → Core/Services/<Capability>Service.swift（协议）+ 实现
├─ 数据模型（跨 feature）      → Core/Models/
├─ 持久化读写实现              → Core/Storage/
├─ 纯函数工具（无 UI 无 IO）   → Core/Utilities/
└─ 组合根 / 窗口 / 场景 / 菜单  → App/
```

判不准时：**先问用户**，别把新东西塞进最近的 View 里。

## 2. 正例 / 反例

| 反例 | 为什么错 | 改成 |
|------|----------|------|
| View 里 `URLSession.shared.data(...)` | View 做了 IO，无法测试、无法 mock | 提到 Service 协议，View 调 Model，Model 调协议 |
| View 里 `try? FileManager.default.contents(...)` | 静默失败，出错无感知 | Service 内 `throws`，Model 转成可展示错误 |
| Model 里 `import SwiftUI` 只为用 `Color` | 状态层耦合 UI，无法在测试/后台复用 | Model 只存语义值（枚举/字符串），View 映射样式 |
| 两个 feature 互相 `import` 对方 View | feature 耦合，改一个炸两个 | 共享组件上提 `UI/`，共享能力上提 `Core/Services` |
| `static let shared = ...` 全局单例随处取 | 隐式依赖，测试与多窗口互相污染 | 组合根构造，`@Environment` 注入 |
| `Core/Services` 里 `import Features.Settings` | 反向依赖，层级倒挂 | 把被依赖的类型下移到 `Core/Models` |
| 为「以后可能换实现」先写 `Repository/UseCase/Interactor` 三层 | 过度设计，抽象无第二个实现 | 先一个协议 + 一个实现，需要时再拆 |
| 一个 `ViewModels.swift` 塞 5 个模型 | 违反一个类型一个文件 | 拆成 `<Type>.swift` |

## 3. 并发与隔离

- **UI 状态一律 `@MainActor`**：`View`、`@Observable` 模型默认主线程。
- 后台工作放 `Task` / `actor`；跨隔离域传值用 `Sendable`（模型优先 `struct` + `let`）。
- **禁止**在后台线程直接改 UI 状态；`await MainActor.run` 或把方法标 `@MainActor`。
- 取消：`Task` 用完要能取消（`view.task` 自动取消；手动 `Task` 记得存引用并 `cancel()`）。
- 不要用 `DispatchQueue.main.asyncAfter` 做状态同步的补丁。

## 4. 状态归属

| 状态 | 放哪 |
|------|------|
| 只在一个 View 内部用 | `@State`（含 `@State private var model = Model(...)`） |
| 一个 feature 内多视图共享 | feature 的 `@Observable` 模型，由父 View 持有并下传 |
| 全 App 共享（连接状态、偏好设置） | `App/` 组合根构造的 environment 对象 |
| 需要跨启动保留 | 持久化（`Core/Storage`），不要靠 `UserDefaults` 散落读取 |

原则：**状态尽量往下沉，作用域能小则小**。上提需要理由，下沉不需要。

## 5. Feature 骨架检查

新增 `<Feature>` 后应满足：

- [ ] 目录内只有该功能真正需要的文件
- [ ] 至少一个 View + 一个 Model；有 IO 就有对应 Service 协议
- [ ] 无 `Features/*` 之间的 View 互引
- [ ] Preview 用假实现，能在不连真实系统的情况下渲染
- [ ] 用到的可复用组件已放 `UI/`（如确实复用）
- [ ] `plan/CURRENT.md` 记录进度
