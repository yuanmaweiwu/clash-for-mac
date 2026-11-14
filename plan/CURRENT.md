# 当前进度

> 更新：2026-11-13
> 保持短（建议 ≤80 行）；过长先压缩：过期已完成收成摘要，长文移 `plan/<topic>.md`。

## 目标

macOS 原生 Clash 客户端：状态栏「控制中心」风格，自带 mihomo，系统代理 + TUN，多订阅。

## 已完成

**工程与文档**
- `Clash.xcodeproj`（同步文件夹、arm64、ad-hoc）；`Scripts/fetch-kernel.sh`、`dev-app.sh`、两个自检脚本
- 文档：`00-PRODUCT` / `01-ARCHITECTURE` / `02-UI-SPEC` / `03-ROADMAP` / `ADR 0001–0010` / `README`
- 技能：`swiftui-app`、`architecture`、`plan`、`git`、`core-process`、`menubar-ui`、`system-proxy`

**内核与配置**
- 内核 / geodata 运行时下载：包内只留 VERSION + SHA256-<arch>；自动三档下载源（直连 / 预置镜像 / 自定义）+ SHA256 校验 + 临时文件清理（ADR-0012）
- 双架构（arm64 + x86_64）+ 可选内置内核变体（`CLASH_BUNDLE_KERNEL=1`），Release 出 4 个包（`adr/0001` 补充）
- 设置页「内核」段：当前版本 / 检查更新（只发一次 API、不下载资产）/ 确认后升级（`-v` 自检 + 停→换→起）
- runtime 配置生成（Yams 解析重写、端口/secret/DNS 注入、`-t` 校验、原子写）
- 内核生命周期：App 启动静默拉起、关代理不停内核、崩溃分类、孤儿回收、端口预检
- 退出清理：SIGTERM/SIGINT/SIGHUP + ⌘Q；`kill -9` 靠快照兜底
- 订阅库：导入（URL/本地）、UA 重试、`subscription-userinfo` 映射、更新/切换/删除/重命名、定时字段
- 真实 `/proxies`：策略组、节点、选择、测速、模式切换；过滤机场伪节点；延迟三态

**接管流量**
- 系统代理：快照 → 写入 → 读回校验 → 失败回滚；启动兜底还原
- TUN：特权 helper（LaunchDaemon + XPC 白名单）、一次管理员授权、`applyRuntimeConfig` 传正文、真订阅实测接管（utun + `128.0/1`）与复原
- 互斥：TUN ↔ 系统代理；配置变更后 TUN 自动重开

**界面**
- 340pt 面板：状态条、四磁贴（订阅磁贴 = 商家名 + 到期/用量 + 满宽 3pt 用量条）、60 点流量曲线、网络检测一排 4 磁贴（Google / GitHub / Apple / YouTube，真实 URLSession 延迟、5s 超时、60s 自动重测）、策略组卡（pin、选中置顶、延迟排序）
- 面板最大高 680：固定头部（状态条 / 磁贴 / 曲线）+ 可滚动尾区（网络检测 + 策略组）+ 固定底栏；双卡满态 680、单卡 634、空态 602
- 底栏 32pt：左本 App 版本号，右连接列表 / 规则 / 设置三个图标（不再有更新时间、刷新、连接数、内核版本）
- 二级页：节点列表（批量测速）、全部策略组、订阅管理（读取中 / 读取失败可重试 / 空库三态）、连接列表、规则列表（`GET /rules`，缓存 + 重试，行高 40）
- 窗口：日志（WS、筛选、暂停、导出、脱敏）、设置（端口/UA/日志级别/开机自启/组件管理/完全清理）

**内存（`footprint` 口径）**
- 面板收起时流量只进缓冲、不发布；曲线 `Canvas` → `Shape`；SwiftUI 树首次上屏才建
- 实测：空闲 39 → 17MB，面板关 + 1MB/s 流量 95 → 17MB，面板开 + 流量 29MB，峰值 95 → 31MB，`IOAccelerator` 55.9M → 16K（常驻）

## 下一步

1. `v0.4` 收尾：图标 + 一组一致的真截图（`docs/images/`）→ README 定稿
2. 用户点「更新组件…」把 helper 升到 v2（文件日志 + 运行时自检），随后验日志双写
3. 退出路径回归：TUN 开着时 ⌘Q 与 `kill -9` 各一次
4. 可选增强：设置项「关闭代理时保留内核」之外的启动行为、策略组 pin 持久化跨订阅、`build-release` 技能

## 待评估（明确不做，先记着）

- **多内核自适应**（mihomo / sing-box / Xray）：用户未来可能集成，当前不做。届时抽象 `CoreProvider`（配置翻译 + API 适配两件事），sing-box 是唯一划算的第二内核（有 `clash_api` 兼容层）；Xray 没有策略组模型，接进来等于重做 UI 与配置层。**现在不写空壳抽象。**

## 关键上下文（续作必读）

- 分支 `test`；remote 为内网 Gitea
- 无代码签名身份、不上架：ad-hoc 签名，Gatekeeper 由用户手动允许；helper 用一次性管理员授权装 LaunchDaemon（`adr/0008`）
- 系统代理**不需要 root**（管理员账号直调 `networksetup`，实测）；helper 只为 TUN
- 内核 `-d` 目录：本地 `/Library/Application Support/Clash/kernel`，TUN 用 `/Library/Application Support/ClashHelper`（root，需 `geoip.metadb`）
- 数据：`~/Library/Application Support/Clash/`（settings.json、profiles/、runtime/、logs/、快照）

## 不要做

- 不要 `-g` 装全局技能；不要引用用户级技能
- 不要擅自引入依赖（仅 Yams 已批）
- 不要 push / 远程写
- 不要改写用户配置；不要在无快照时改系统代理
- 不要提交订阅内容、节点名、token、`geoip.metadb` 等产物
