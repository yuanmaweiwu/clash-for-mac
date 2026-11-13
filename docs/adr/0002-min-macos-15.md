# ADR-0002 · 最低支持 macOS 15 Sequoia

- 状态：已接受
- 日期：2026-11-13
- 相关：`.agents/skills/swiftui-app/SKILL.md` §1

## 决定

最低部署目标 `macOS 15.0`；开发与验收使用最新版 Xcode（Swift 6 语言模式）。

## 理由

1. `@Observable`（Observation）、`MenuBarExtra(.window)`、`SMAppService`、`@Entry`、新的 `ScrollView` 表现等都可在 15 上放心使用
2. 本产品只在个人 Mac 上使用为主，15 的用户覆盖足够；不为 13/14 付兼容税
3. 后续 Apple 新 API（如 26 的玻璃材质）可用 `if #available` 增量接入，不阻断基线

## 被否方案

| 方案 | 否决原因 |
|---|---|
| macOS 13 | 要退回 `ObservableObject` + `@Published`，`MenuBarExtra` 窗口行为也更差 |
| macOS 14 | 收益小：仅多覆盖一代用户，却要放弃 15 的若干修正 |
| macOS 26 only | 用户面过窄，且新材质/新 Scene API 尚在演进 |

## 后果

- 所有代码默认可用 `@Observable`，**禁止**再用 `ObservableObject` / `@Published` 写新代码
- 严格遵守 Swift 6 并发检查；跨 actor 一律 `Sendable` DTO
- 若某个 26+ 特性对体验提升明显（如新玻璃材质），单独做可用性判断，不作为基线
- CI / 构建机需 Xcode 16+（以实际要求为准，写入 `swiftui-app` §6）
