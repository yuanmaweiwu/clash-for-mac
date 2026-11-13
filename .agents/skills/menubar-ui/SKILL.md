---
name: menubar-ui
description: "状态栏（菜单栏）应用与控制中心风格浮层的实现约定：MenuBarExtra 用法与坑、NSPanel 升级路径、面板结构、材质与层级、动画与可访问性、状态栏图标与速率显示。凡写/改面板 UI、状态栏图标、浮层尺寸、材质、动效、键盘交互时加载。触发词：状态栏、菜单栏、MenuBarExtra、popover、NSPanel、控制中心、毛玻璃、浮层、图标、面板。"
---

# 状态栏 UI：控制中心风格

> 视觉数值（Token、尺寸、颜色、动效参数）只在 [`docs/02-UI-SPEC.md`](../../../docs/02-UI-SPEC.md)；本技能管**怎么实现、别踩什么坑**。
> 通用 View/状态写法看 `swiftui-expert-skill`；分层与目录看 `architecture`。

## 1. 硬结构

- `LSUIElement = true`：无 Dock 图标、无主菜单栏；设置窗口按需创建
- 进入方式只有一个：状态栏图标点击 → 浮层
- 浮层 = 遥控器：**最多一屏**，不滚动的部分必须能放下最常用 6 个动作
- 设置窗口是独立 `Window` scene（⌘, 打开），浮层里只放入口，不嵌设置表单
- 三级信息深度上限：面板（状态/开关/选择）→ 弹层（列表/详情）→ 窗口（配置）

## 2. MenuBarExtra：先用它，留好退路

```swift
MenuBarExtra {
    PanelView()
} label: {
    StatusItemLabel()
}
.menuBarExtraStyle(.window)
```

必须知道的坑：

1. `.window` 风格的尺寸由内容决定，内容宽度要**显式固定**（`frame(width:)`），否则首次展开会抖
2. 高度变化时用 `animation` + 固定锚点，避免展开过程跳动；长列表用「固定最大高 + 内部滚动」
3. 系统会在失焦时自动关闭；不要依赖 `onDisappear` 做业务清理（它可能不按预期触发），状态归 Service
4. `MenuBarExtra` 内不要放 `Settings`/`WindowGroup` 跳转逻辑；用 `openWindow` / `SettingsLink`
5. 首次安装时状态栏图标在「控制中心」之外，用户可能找不到 → 首次启动给一次引导
6. 图标用 `Image(nsImage:)` 设 `isTemplate = true`，颜色随菜单栏自适应；不要用彩色 SF Symbol

**已升级（`adr/0011`）**：本仓库现在就是 `NSStatusItem` + `NSPanel`（因为需要右键菜单与「完全退出」）。下面保留原始判断依据，供其它项目参考：

**升级到 AppKit 的信号**（满足任一才换 `NSStatusItem` + `NSPanel`）：

- 需要自定义「点击外部不关闭」或拖拽固定面板
- 需要面板出现在多屏指定位置 / 全屏 Space 上
- 需要更精细的出现动画（锚点、跟随）
- 换的时候只替换容器，`PanelView` 及其模型不动

## 3. 材质与层级

- 面板底：`NSVisualEffectView`（`.popover` / `.hudWindow`）或 SwiftUI `.ultraThinMaterial`；**只用一种**，不要在同一个面板里混两种模糊
- 卡内分区：不透明语义色（`Color(nsColor: .controlBackgroundColor)` 级别）+ 1px 语义描边
- **禁止**：彩色渐变背景、大色块标题栏、阴影叠三层、半透明叠半透明（会糊）
- 深浅色：只写语义色，不写 `Color.black.opacity(...)` 这种硬编码；需要固定黑/白时用 `Color(nsColor: .windowBackgroundColor)`

## 3.5 语义色必须能跨线程解析（实测崩过）

用 `NSColor(name:dynamicProvider:)` 做浅/深色 Token 时，**provider 闭包必须是 nonisolated**：
SwiftUI 会在 DisplayLink 后台线程解析动态色，若闭包继承了 `@MainActor`（例如直接写在一个 `@MainActor enum` 的静态属性里），会以
`dispatch_assert_queue_fail` / `EXC_BREAKPOINT` 崩溃，且 `swift build` 完全通过、启动几秒后才炸。

正确写法：

```swift
// 自由函数，nonisolated —— 不要放进 @MainActor 类型
private func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

@MainActor enum Theme {
    static let card = Color(nsColor: dynamicColor(light: .white, dark: .black))
}
```

自检：`Theme` 里的 `static let` 只允许调用 nonisolated 工厂函数；出现 `@MainActor` 上下文的 provider 闭包即视为缺陷。

## 4. 动效

- 只用两类：磁贴/开关（短、快，~150ms spring）、列表与面板内容切换（~200ms easeOut）
- 展开/折叠同族元素用 `matchedGeometryEffect`；**不要**给每个子项单独加弹簧
- 数值（速率、延迟）变化用 `contentTransition(.numericText())`，不要整块重绘
- `accessibilityReduceMotion` 为真时：所有位移/缩放降为 0，仅保留透明度或直接瞬时切换
- 曲线/图表滚动禁止 `TimelineView` 高频刷新整棵树；用固定采样缓冲 + `Canvas`

## 5. 状态表达

**唯一口径**：图标语义 = 「是否正在接管流量」，不是「内核是否在跑」。下表与 `docs/02-UI-SPEC.md` §3.3 / §4.1 一致，改动须两边同步。

| 内核 / 代理态 | 状态栏图标 | 状态条文案 | 速率 |
|---|---|---|---|
| 未运行 | 描边剪影 + 45° 斜线 | 未运行 | `—` |
| 启动中 / 停止中 | 同未运行 + 6pt `ProgressView` | 启动中 / 停止中 | `—` |
| 运行 · 未接管（系统代理关） | 描边剪影 | 已就绪 | 实时 |
| 运行 · 接管中（系统代理或 TUN 开） | 实心剪影 | 代理中 | 实时 |
| 运行 · 模式=直连 | 描边剪影 | 直连 | 实时 |
| 失败 / 断连 | 实心剪影 + 右下 3pt `error` 圆点 | 启动失败 / 连接中断 | `—` |

- 状态栏图标**不显示**长文字；速率文字默认关闭，开启后仅面板收起时显示（如 `↓8.4`）
- 颜色只用语义：正常/警告/错误；不要把「延迟高低」映射成红绿大字
- 「接管中」只允许一个来源判定（系统代理开 **或** TUN 开）；两者不可同时呈现「半开」

## 6. 交互与键盘

- `Esc` 关闭面板；`⌘,` 打开设置；`⌘Q` 退出（退出前若有代理开启，按设置决定是否还原）
- Tab 顺序 = 视觉顺序；所有控件必须有可见 focus ring（自定义按钮要自己画）
- 右键状态栏图标 → 短菜单（打开设置 / 退出）；左键 → 面板
- 长按/双击不做隐藏功能

## 7. 可访问性（必做，不是加分项）

- 图标：`accessibilityLabel("Clash，代理已开启")`
- 磁贴：`accessibilityValue("开启/关闭")` + `accessibilityHint`
- 速率：`accessibilityLabel("上传 1.2 兆字节每秒，下载 8.4 兆字节每秒")`，不要读原始数字串
- 节点行：组名 + 当前节点 + 延迟，一次读全
- 对比度 ≥ 4.5:1（正文）；装饰性分隔线不进无障碍树（`.accessibilityHidden(true)`）
- 字号：面板固定尺寸、**不随 Dynamic Type 放大**（与系统控制中心一致）；设置窗口与日志等自由排版界面**必须**支持 Dynamic Type；两者都要响应「加粗文本」

## 8. 反模式清单

- ❌ 面板里塞设置表单 / 订阅编辑 / 日志全文
- ❌ 用 `ScrollView` 包整个面板（导致「一屏遥控器」失效）
- ❌ 自绘一套按钮外观（与系统控件不一致，深浅色必翻车）
- ❌ 在 View 里直接调 `ClashAPIClient` 或读文件
- ❌ 用 `Timer` 驱动 UI 刷新（用 Service 的 `AsyncStream` + 缓冲）
- ❌ 面板里出现超过 2 种字号层级之外的字重

## 9. 验收

- [ ] 浅色/深色/提高对比度三种设置下都检查过
- [ ] Reduce Motion / Reduce Transparency 打开后仍可用且不糊
- [ ] 全键盘可完成「开代理 → 切节点 → 关代理」
- [ ] VoiceOver 逐项走查，无「按钮」空读
- [ ] 面板首次展开无尺寸跳动；连续开关 20 次无残留动画
- [ ] 数值与尺寸全部来自 Token，无散落魔法数
