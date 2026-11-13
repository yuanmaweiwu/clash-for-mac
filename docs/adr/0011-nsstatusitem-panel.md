# ADR-0011 · 状态栏改用 NSStatusItem + NSPanel

- 状态：已接受
- 日期：2026-11-13
- 相关：`adr/0009`（设计语言）、`.agents/skills/menubar-ui/SKILL.md` §2

## 背景

`MenuBarExtra(.window)` 能开浮层，但**无法提供右键菜单**——右键与左键行为一致，都只是打开面板。用户需要右键里能「完全退出」，这是菜单栏应用的常规预期，也是唯一不打开面板就能退出的入口。

`menubar-ui` §2 早已列出「需要自定义右键菜单」是切换到 AppKit 的信号之一，现在正好命中。

## 决定

用 `NSStatusItem` + 自建 `NSPanel` 替换 `MenuBarExtra`：

- 左键：开/关面板（同一份 `PanelView`，宽度仍 340，高度按内容）
- 右键：`NSMenu`——**只有 日志 / 退出 Clash（⌘Q）**。不提供「打开面板」（左键即可）与「设置」（面板内页 + ⌘,），菜单越短越不容易误点
- 面板窗口：`.borderless + .nonactivatingPanel`、`level = .popUpMenu`、透明背景，失焦即关
- 退出走 `NSApp.terminate` → `applicationWillTerminate` → `AppTerminationGuard`（撤代理 → 停 TUN/内核），禁止 `exit(0)` 绕过

## 被否方案

| 方案 | 否决原因 |
|---|---|
| 在 `MenuBarExtra` 的 label 里塞 `NSView` 捕获右键 | 依赖私有行为，系统更新易碎；且无法保证菜单层级与键盘交互 |
| 右键也打开面板、面板里放「退出」 | 用户明确要的是右键菜单；且系统关机/无网时更需要「不打开面板就能退」 |
| 挂一个 `NSMenu` 到 menu bar extra 的 button | SwiftUI 不暴露底层 button |

## 后果

- 面板的尺寸、定位、失焦关闭都要自己管（原先由系统负责）——用 `fittingSize` + 屏幕夹取兜底
- `LSUIElement` 应用没有主菜单，需要自建最小 main menu 才能让 ⌘Q 在面板聚焦时生效
- 图标绘制从 SwiftUI `Image` 变成 `NSImage` 模板图，状态切换逻辑集中在 `StatusItemController`
- 好处：右键菜单、面板层级、锚点定位、多屏行为都可控，后续加「开机自启」「检查更新」等菜单项不再受框架限制
