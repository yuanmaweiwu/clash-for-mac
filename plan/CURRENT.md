# 当前进度

> 更新：2026-11-13
> 保持短（建议 ≤80 行）；过长先压缩：过期已完成收成摘要，长文移 `plan/<topic>.md`。

## 目标

做一款 macOS 原生的 Clash 客户端：状态栏「控制中心」风格，v1 含 TUN，自带 mihomo 内核。

## 已完成

- [x] Agent 技能体系：`swiftui-app` / `architecture` / `plan` / `git` + 外部 `swiftui-pro`、`swiftui-expert-skill`（项目级 vendor）
- [x] `铁律 0`：技能只装项目级（`.agents/skills/`），禁止 `-g` 与用户级目录
- [x] 产品文档：`docs/00-PRODUCT.md`（定位、范围、术语、合规）
- [x] 架构文档：`docs/01-ARCHITECTURE.md`（helper + XPC 进程模型、配置流水线、API 面、代理还原）
- [x] 路线图：`docs/03-ROADMAP.md`（v0.1 → v1.0 + 风险登记）
- [x] ADR 0001–0005（自带内核 / macOS 15 / 手写 xcodeproj / TUN 与 helper 进 v1 / Yams 定案）
- [x] 依赖定案：`Yams` 为唯一第三方解析库，Sparkle 到 v1.0；界面中文为主、预留本地化
- [x] 技能补齐：`core-process`（内核/API/TUN）、`menubar-ui`（状态栏/浮层）、`system-proxy`（代理快照还原）
- [x] UI 规范 `docs/02-UI-SPEC.md`：Token / 340×640 面板结构 / 组件四态 / 7 处动效 / 无障碍 / 空错态
  - 已裁定冲突：状态栏图标语义统一为「是否接管流量」；Dynamic Type 分场景（面板固定、设置窗口支持）
- [x] 内核获取：`Scripts/fetch-kernel.sh` 取上游 latest arm64；已实测 v1.19.34（arm64，57MB）
- [x] 真实订阅联调（2026-11-13）：UA 门禁（陌生 UA → 422）、重复键注入失败、`expire` 缺失、`Profile-Update-Interval: 1h`、主组名为机场名、订阅自带 `allow-lan: true` / `dns.listen 0.0.0.0` → 全部写进文档与 `adr/0006`

## 进行中

- [x] 可交互原型 `Prototype/`：菜单栏真浮层 + 演示窗口，六个动作可点，订阅库 3 条，按延迟排序，测速互斥
- [x] 原型视觉收敛：胶囊 28pt / 卡内上下 4pt 呼吸区 / 卡内无横线 / 1pt 连续描边 / 选中无 ✓ / 选中置顶
- [ ] 用户实操反馈 → 继续微调
- [ ] 原型交互评审：多订阅 / 策略组 pin 刚定，需同步到原型后再给用户试

## v0.1 已完成（2026-11-13）

- [x] `Clash.xcodeproj`（同步文件夹、arm64、ad-hoc）、`MenuBarExtra` 浮层、面板 UI 全量移植
- [x] 真内核：runtime 配置生成 → `-t` 校验 → 启动 → `/version` 就绪判定 → 停止/崩溃分类
- [x] 面板去假象：v0.1 只到「已就绪」，速率/曲线/连接数/TUN 均按实况显示
- [x] 实测：真点击启动 → `mihomo` 进程 → `/version` v1.19.34 → 再点停止无残留

## v0.2 进行中

- [x] 订阅库（导入/更新/切换/删除/重命名、UA 策略、订阅头映射）
- [x] 系统代理开关 + 快照还原 + 启动兜底
- [x] 真实 `/proxies` 节点、点选、测速、模式切换；过滤机场伪节点
- [x] 内核与代理解耦（启动自动起内核，关代理不停内核）
- [x] 退出清理：SIGTERM/SIGINT/SIGHUP + ⌘Q；`kill -9` 靠快照兜底
- [x] 孤儿内核回收 + `mixed-port` 预检
- [ ] 流量 WS（速率与曲线仍是 `—`）
- [ ] 连接列表与日志窗口
- [x] 设置窗口（端口 / UA / 日志级别 / 开机自启 / 关代理保留内核 / 完全清理），`settings.json` 原子写 + 损坏备份；端口与级别的变更提示重启内核
- [x] 特权 helper + XPC（`ping` / `applyRuntimeConfig` / `startKernel` / `stopKernel` / `kernelState`）+ 安装/卸载脚本（未安装）
- [x] TUN 协议 v2：配置正文经 XPC 送达，helper 校验（Yams 顶层映射）+ 原子写 0600 root:wheel，**不自动启动**
- [x] `RuntimeConfigBuilder` TUN 段：开 → 整段覆盖 + fake-ip DNS；关 → 只留 `tun.enable=false`
- [x] `TunService` 状态机（off / needsInstall / awaitingAuthorization / starting / on / stopping / failed）+ 与系统代理互斥
- [x] TUN 磁贴五态 + 安装说明卡（改成 SwiftUI alert，不用 `NSAlert.runModal`）+ 失败后必可重试
- [x] 退出清理：TUN 开着时 `stopKernel` 同步确认（1.5s 上限）+ 启动时回收遗留 root 内核
- [x] 真机验证（2026-11-13）：root mihomo → utun4=198.18.0.1 → `/version` 就绪 → 关闭后
  utun 消失、`128.0/1` 分流路由清空、无残留进程；非法 YAML 被 helper 拒并给中文原因
- [x] **geodata 已补齐**（真机 `geoip.metadb` 落位），真订阅 TUN 实测：utun4 + `128.0/1` + 直连 204
- [x] 设置窗口「特权组件」：未安装 / 已安装·版本 N / 需要更新 / 已装未运行 四态 + 安装/更新/重新安装/卸载
- [x] TUN 自动重开：订阅更新、端口 / 日志级别 / LAN 变更 → 关 → 换配置 → 重开；失败停在关闭态
- [x] TUN 的 DNS 兜底：订阅没写 `nameserver` 时注入 `223.5.5.5`、`1.1.1.1`
- [x] 退出预算：TUN 内核等待 1.5s → 2.0s（总预算仍 ≤3s）
- [ ] 当前机器上的 helper 还是旧格式（无文件日志、无运行时自检）→ 设置里显示「需要更新」，更新后 `helper.log` 才有内容

## 下一步（按优先级）

1. 设置里点「更新组件…」把 helper 升到带文件日志 + 运行时自检的版本；随后 `log show --predicate
   'subsystem == "com.clash.helper"'` 与 `sudo tail helper.log` 验证双写
2. 退出路径真机验证：TUN 开着 → ⌘Q（2s 同步 stop）与 `kill -9`（启动时回收）各一次
2. 真实节点数据：Yams 配置合并 + `profiles/index.json` + 订阅导入（进行中）
2. `ProxyService`：`/proxies` 策略组与节点、选择、测速、`PATCH /configs` 模式
3. helper（管理员授权安装）+ 系统代理快照还原
4. 流量 WS + 连接列表
2. 补齐技能（全部项目级）：`swift-style`、`build-release`
3. v0.1 骨架：`.xcodeproj`（App / Helper / Tests）+ `MenuBarExtra` 空面板 + helper 安装 + 内核启停 + `/version`
4. 内核签名与 helper spawn 校验方案（v0.1 内落地）

## 关键上下文（续作必读）

- 分支 `test`；remote 为内网 Gitea（`http://内网地址:3000/Clash/Clash.git`）
- 已定：macOS 15+ / **仅 arm64** / Swift 6 / `.xcodeproj` 手写 / 自带 mihomo / v1 含 TUN / 设置 JSON + 配置 YAML
- **无代码签名身份、不上架**：ad-hoc 签名；helper 用「一次管理员授权装 LaunchDaemon」（`adr/0008`），v0.1 先由 App 用户态直启内核（`adr/0007`）
- v0.2 起系统代理/TUN 依赖 helper 安装流程，属于必做项，不再等证书
- 架构要点：**helper（root）是内核与系统写操作的唯一持有者**；App 只通过 XPC + mihomo HTTP/WS 通信
- 配置原则：用户 YAML 永不改写，注入只进 `runtime/`；订阅库多条、单条 active、`pinnedGroups` 只是 UI 偏好
- **TUN 的 geodata 是硬依赖**：`mihomo -d` 目录里要有 `geoip.metadb` / `geosite.dat`，缺失时内核
  会在线下载（国内 90s 超时，表现为「8 秒未就绪」）；`Scripts/fetch-kernel.sh` 已会拉，安装脚本会拷
- 构建命令已写入 `.agents/skills/swiftui-app/SKILL.md` §6（工程创建后需实测修正）
- 唯一 Swift 代码在 `Prototype/`（可交互原型，未接内核；正式工程 v0.1 再建）

## 不要做

- 不要 `-g` 安装全局技能；不要引用用户级技能
- 不要擅自引入依赖（仅 Yams 已批；SwiftData / GRDB / Alamofire / 第三方 UI 库已否）
- 不要 push / 远程写（须用户当轮明确要求）
- 不要改写用户配置、不要在无快照情况下改系统代理
- 不要为「以后可能用」建空抽象、空目录
