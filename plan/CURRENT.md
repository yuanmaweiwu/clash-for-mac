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
- 340pt 面板：状态条、四磁贴（订阅磁贴 = 商家名 + 到期/用量 + 满宽 3pt 用量条）、60 点流量曲线、策略组卡（pin、选中置顶、延迟排序）
- 底栏 32pt：左本 App 版本号，右连接列表 / 设置两个图标（不再有更新时间、刷新、连接数、内核版本）
- 二级页：节点列表（批量测速）、全部策略组、订阅管理（读取中 / 读取失败可重试 / 空库三态）、连接列表
- 窗口：日志（WS、筛选、暂停、导出、脱敏）、设置（端口/UA/日志级别/开机自启/组件管理/完全清理）

## 下一步

1. `v0.4` 收尾：图标 + 一组一致的真截图（`docs/images/`）→ README 定稿
2. 用户点「更新组件…」把 helper 升到 v2（文件日志 + 运行时自检），随后验日志双写
3. 退出路径回归：TUN 开着时 ⌘Q 与 `kill -9` 各一次
4. 可选增强：设置项「关闭代理时保留内核」之外的启动行为、策略组 pin 持久化跨订阅、`build-release` 技能

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
