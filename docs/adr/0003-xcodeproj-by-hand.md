# ADR-0003 · 工程形态：手写 .xcodeproj 入库

- 状态：已接受
- 日期：2026-11-13
- 相关：`docs/01-ARCHITECTURE.md` §2

## 决定

使用 Xcode 原生 `.xcodeproj`，手工维护并提交进仓库。不引入 XcodeGen / Tuist。

## 理由

1. 必须有多个 target（App、Helper、Tests）与 entitlements、LaunchDaemon plist、内嵌二进制拷贝阶段；SPM 单包做不了
2. 单人 + 少量 target，工程文件冲突风险低，生成器带来的收益 < 学习与维护成本
3. 打开即用，无需「先跑一条命令生成工程」的前置步骤

## 被否方案

| 方案 | 否决原因 |
|---|---|
| SPM 单包 + 手写打包脚本 | 无法表达 app bundle / helper / 签名配置，脚本会越写越像工程文件 |
| XcodeGen | 多一层依赖与安装步骤；本项目 target 数少，`project.yml` 的抽象收益有限 |
| Tuist | 能力过剩，构建缓存与模块化收益在单 app 上体现不出来 |

## 后果

- 工程文件必须可读：target / build phase 命名清晰，不塞自定义脚本做隐式魔法
- 构建命令固定为 `xcodebuild -project Clash.xcodeproj -scheme Clash -configuration Debug build`（写入 `swiftui-app` §6）
- 若后续出现「工程文件反复冲突」或「多环境配置漂移」的实际痛点，再单独评估迁移到生成器（届时新开 ADR）
- 不提交 `xcuserdata`、`DerivedData`
