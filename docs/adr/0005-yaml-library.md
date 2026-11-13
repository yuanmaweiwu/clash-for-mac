# ADR-0005 · YAML 处理与第三方依赖策略

- 状态：已接受（2026-11-13 用户确认）
- 日期：2026-11-13
- 相关：`docs/01-ARCHITECTURE.md` §4

## 决定

1. 允许引入 **Yams**（Swift YAML 解析，MIT）作为唯一解析依赖
2. 其余能力全部用系统框架；不引入网络库、UI 库、响应式库、数据库
3. Sparkle 2 仅在 v1.0 接自动更新时引入（另一条 ADR）

## 理由

- 运行配置生成需要「解析 → 覆盖顶层键 → 序列化」，字符串拼接在 YAML 里不可靠（锚点、多文档、重复键、缩进）
- mihomo 的 `-t` 只能校验，不能替我们改写配置
- Yams 纯 Swift、无额外传递依赖，符合最低依赖原则

## 被否方案

| 方案 | 否决原因 |
|---|---|
| 字符串拼接注入 | 实测直接失败：把 `mixed-port` 等追加到真实订阅末尾，`mihomo -t` 报 `mapping key "mixed-port" already defined at line 1` |
| 零依赖手写解析器 | 边界情况（多文档、块标量、转义）极易翻车，不值得 |
| SwiftData / GRDB 做持久化 | v1 数据量小（设置 JSON + 少量 YAML），引入迁移成本反而更大 |
| 引入 Alamofire / 第三方 UI 库 | 系统框架足够；第三方 UI 会破坏原生观感与可访问性 |

## 后果

- 依赖声明在 `.xcodeproj` 的 Swift Package 依赖里，仅 Yams 一项；不使用其它包管理器
- 增加依赖需新开 ADR，并在 `plan/CURRENT.md` 记录
- 订阅「原样保存」：解析只为生成 runtime，不做规范化回写
