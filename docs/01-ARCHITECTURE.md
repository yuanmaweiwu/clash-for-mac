# 01 · 架构（Clash for macOS）

> 状态：v1 基线 · 最后更新 2026-11-13
> 与 `00-PRODUCT.md` 对齐；本文确定进程模型、模块边界与数据流，落地细节以实码为准。

## 1. 进程模型

```
┌─────────────────────────────┐        XPC          ┌──────────────────────────┐
│ App（用户级, LSUIElement）    │◄──────────────────►│ helper（root, LaunchDaemon）│
│ SwiftUI 面板 / 设置 / 状态     │   NSXPCConnection   │ 唯一的内核与系统写操作持有者  │
└──────────────┬──────────────┘                     └───────────┬──────────────┘
               │ HTTP/WS 127.0.0.1:port                          │ spawn / signal
               ▼                                                 ▼
        ┌──────────────────────────────────────────────────────────────┐
        │ mihomo（系统代理模式：drop 到登录用户 / TUN 模式：root）          │
        └──────────────────────────────────────────────────────────────┘
```

**为什么 helper 持有内核，而不是 App 直接 spawn：**

1. TUN 必须 root 启动内核，v1 就有 TUN → 迟早要 helper
2. 系统代理（`networksetup`）：**实测管理员账号在 App 进程内可直接修改，不需要 root**（见 `adr/0008` 补充），因此不必经 helper
3. 内核生命周期与 App 解耦：App 崩溃时内核可选择继续跑，helper 负责回收
4. 一处实现两处复用，避免「App 能启、TUN 不能启」的双路径

**降权规则**：系统代理模式下，helper 用 `posix_spawn` 以登录用户的 uid/gid 启动 mihomo，配置目录归用户所有，避免 root 写用户文件造成权限污染。TUN 模式下以 root 启动。

**App 与内核的关系**：App 不持有内核进程句柄，只通过 helper 下达「启动/停止」，通过 mihomo HTTP API 读状态。helper 崩溃 → App 侧走断连态，提供「重启 helper」。

## 2. 模块与目录

```
App/
  ClashApp.swift            @main、MenuBarExtra / 设置窗口场景
  AppDelegate.swift         LSUIElement、激活策略、退出清理
  AppEnvironment.swift      依赖装配（唯一允许的容器）
Core/
  Models/                   Profile、ProxyGroup、Node、TrafficSample、KernelState…
  Services/                 协议 + 实现
    KernelService.swift     helper XPC 客户端：start/stop/status
    ClashAPIClient.swift    mihomo RESTful + WebSocket
    ProfileStore.swift      配置落盘、订阅更新、runtime config 生成
    SystemProxyService.swift 代理开关 + 快照还原（经 helper）
    SettingsStore.swift     JSON 设置
    UpdateService.swift     Sparkle（v1.0 接）
  Storage/                  文件布局、原子写、迁移
  Utilities/                YAML 注入、端口探测、格式化
Features/
  Panel/                    状态栏浮层（主界面）
  Nodes/                    节点与策略组
  Profiles/                 订阅与配置
  Connections/              连接列表
  Settings/                 设置窗口
UI/
  Tokens/                   Design Token（颜色/间距/圆角/动效）
  Components/               磁贴、分段控件、节点行、流量曲线
Helper/                     LaunchDaemon target（root）+ XPC 协议
Shared/                     App 与 Helper 共用的 XPC 协议与 DTO
Resources/                  Assets、字符串目录、mihomo 二进制、LICENSE
Tests/                      单元测试（YAML 注入、状态机、还原逻辑）
```

依赖方向单向：`Features → Core → Shared`；`UI` 只被 `Features` 使用；`Helper` 只能依赖 `Shared`，**禁止** import App 侧代码。

## 3. 状态机（内核）

```
idle ──start──► starting ──ok──► running ──stop──► stopping ──► idle
                  │                │
                  └──fail──► failed ◄──crash────┘
```

- 状态唯一来源：`KernelService` 的 `@Observable` 状态（`KernelState` 枚举 + 附加原因）
- `failed` 必须带原因（端口占用 / 配置非法 / 二进制缺失 / 签名被拒）
- App 启动时若 helper 报告内核已在运行 → 直接进 `running`（不重复启动）
- 崩溃自恢复：helper 记录最近一次 exit code；非用户停止时最多重启 3 次（指数退避 1s/3s/9s），仍失败则停在 `failed` 并通知

## 4. 配置流水线

```
订阅 URL ──► 下载 YAML ──► 校验（mihomo -t）──► 原样存为 profiles/<id>.yaml
                                                      │
                              应用设置（端口/模式/控制器/secret/TUN）
                                                      ▼
                                           runtime/<id>.yaml（每次启动重建）
                                                      ▼
                                           mihomo -f runtime/<id>.yaml
```

关键约定：

- **用户配置永不改写**：所有注入只写进 `runtime/`，删除即恢复原状
- 注入字段（最小集合）：`mixed-port`、`socks-port`、`port`、`allow-lan`、`mode`、`log-level`、`external-controller: 127.0.0.1:<随机空闲端口>`、`secret: <每次启动随机>`、`dns.listen: 127.0.0.1:<随机空闲端口>`、`bind-address: 127.0.0.1`、`tun.*`
- **安全默认值必须覆盖订阅里的值**：实测真实订阅带 `allow-lan: true`、`dns.listen: 0.0.0.0:1053`——照搬等于把代理与 DNS 暴露到局域网。默认一律收紧为 `allow-lan: false` + `127.0.0.1`，用户显式开启才放开
- **`tun` 段整段替换**（不 merge）：TUN 开 → `enable/stack/auto-route/auto-detect-interface/dns-hijack` 全由 App 决定，`dns` 强制 `enhanced-mode: fake-ip` + `fake-ip-range: 198.18.0.1/16`；TUN 关 → 只写 `tun.enable: false`，不复用订阅里的 tun 配置
- **TUN 模式下配置正文经 XPC 送 helper**（`adr/0010`）：App 只生成字符串，helper 校验后原子写 root 目录
- 注入方式：解析原 YAML → 覆盖顶层键 → 输出；**不用字符串拼接**。实测把同名键追加到文件末尾会让 `mihomo -t` 直接失败：`mapping key "mixed-port" already defined at line 1`
- secret 只存在内存 + 运行配置；App 存于内存，禁止落盘明文到日志
- 端口冲突：启动前探测，被占用则让用户在设置里改，不静默换端口

### 4.1 订阅库与更新

`profiles/index.json` 是唯一索引（列表元数据，不含配置正文）：

```json
{
  "activeProfileID": "p_01",
  "profiles": [
    {
      "id": "p_01",
      "name": "机场 A",
      "source": { "kind": "url", "url": "https://…" },
      "updatedAt": "2026-11-13T06:00:00Z",
      "autoUpdateHours": 24,
      "lastAttemptAt": "2026-11-13T06:00:00Z",
      "lastError": null,
      "subscriptionInfo": { "upload": 0, "download": 0, "total": 0, "expire": 0 },
      "pinnedGroups": ["节点选择"]
    },
    { "id": "p_02", "name": "本地 规则集", "source": { "kind": "file", "path": "…" }, "autoUpdateHours": 0 }
  ]
}
```

更新流程（App 侧执行，**不需要** root）：

1. `GET <url>`，UA 策略见 [`adr/0006`](adr/0006-subscription-user-agent.md)：默认 `mihomo/<内核版本>`，遇 422 自动换预设 UA 重试一次
2. 读响应头并映射（实测该机场四个头齐全，`expire` 缺失）：
   - `subscription-userinfo: upload=…; download=…; total=…; expire=…` → 缺字段留空，**不猜**
   - `Profile-Update-Interval: <小时>` → 作为**建议**更新间隔（实测为 1 小时）
   - `Profile-Web-Page-Url` → 订阅管理里的「打开订阅页」（续费入口）
   - `Content-Disposition: … filename="X"` → 无名字时作默认 profile 名
3. 生成临时 runtime → `mihomo -t` 校验；失败则保留旧文件，只写 `lastError` / `lastAttemptAt`
4. 校验通过 → 原子替换 `profiles/<id>.yaml` → 更新 index
5. 若它正是 active 且内核在跑 → 重建 runtime → `PUT /configs?force=true`

约束：

- **内核与系统代理解耦**：内核由 App 生命周期管理（有激活订阅时启动、App 退出时停止），系统代理是独立开关。**关代理不停内核**——否则用户没法在不代理的情况下挑节点、测速
- **同一时刻只有一条 active**；切换 = 换 active + 重建 runtime + 重载，不做并存
- 更新失败不清空、不覆盖旧配置；UI 只标记「更新失败」，继续用旧版
- 定时更新由 App 调度（`autoUpdateHours`: 0=手动，1/6/12/24），默认取 `Profile-Update-Interval` 建议值（缺省 24）；只在 App 运行时执行，错过不补跑
- profile 删除前若为 active：先切到另一条或停内核，**不允许删出空 active**
- 订阅 URL 常含 token：日志、错误文案、崩溃报告一律脱敏
- `pinnedGroups` 是 UI 偏好，只存 index，**不注入** runtime 配置
- **主组识别**：首屏第一张卡 = 配置里第一个 `select` 组（实测真实订阅叫「机场A」，不是「节点选择」），名字一律取自配置
- **geodata 共享**：内核 `-d` 目录全 profile 共用一个（首次运行会下载 `geoip.metadb` 约 8MB），不要按 profile 各建一个，否则每份订阅重复 8MB

## 5. 与内核的接口面（只依赖这些）

| 能力 | 接口 |
|---|---|
| 版本/连通性 | `GET /version` |
| 配置热改 | `PATCH /configs`（`mode` / `allow-lan` / `log-level`） |
| 整体重载 | `PUT /configs?force=true` `{path}` |
| 策略组/节点 | `GET /proxies`、`GET /providers/proxies`、`PUT /proxies/{name}` `{name}` |
| 延迟测速 | `GET /proxies/{name}/delay?timeout=&url=`、`GET /group/{name}/delay` |
| 实时速率 | `GET /traffic`（WebSocket，逐秒 `up`/`down`） |
| 日志 | `GET /logs?level=`（WebSocket） |
| 连接 | `GET /connections`、`DELETE /connections`、`DELETE /connections/{id}` |
| 规则 | `GET /rules` |

约定：

- 全部经 `ClashAPIClient`（单个 actor），其他模块不得直接 `URLSession`
- WebSocket 断线重连退避 1s→8s，重连期间 UI 显示「数据暂停」而非清零
- 所有请求带 `Authorization: Bearer <secret>`；监听地址固定 `127.0.0.1`，不暴露 `0.0.0.0`（`allow-lan` 仅影响代理端口，不影响控制端口）

## 6. 系统代理：安全还原

1. 开启前：快照当前所有网络服务的代理状态（web/secure/socks/auto/bypass）到 `Application Support/systemproxy-snapshot.json`
2. 设置：`networksetup -setwebproxy <service> 127.0.0.1 <port>` 等；helper 执行
3. 关闭：按快照逐项还原，成功后才删除快照
4. 崩溃兜底：App 启动时若发现残留快照且内核未运行 → 自动还原（helper 不参与）
5. 卸载：设置里「完全清理」显式还原 + 移除 LaunchDaemon

**禁止**：只改 Wi-Fi、改完不写快照、退出时不还原。

## 7. 权限与安全

- helper 通过**一次性管理员授权**安装为 LaunchDaemon（`adr/0008`）：`osascript … with administrator privileges` 写 `/Library/PrivilegedHelperTools/` + `/Library/LaunchDaemons/` 并 `launchctl bootstrap system`；不用 `SMAppService`（无签名身份无法注册）
- XPC 连接校验：取 `audit token` 的 pid → 反查可执行路径，必须等于当前 App 的 bundle 路径；ad-hoc 签名无 team id，故不依赖签名校验
- helper 只暴露白名单操作（协议 v2，实际实现）：`ping()`、`applyRuntimeConfig(bytes)`、`startKernel()`、`stopKernel()`、`kernelState()`
- 唯一从 XPC 进来的内容是「配置正文」，落盘路径由 `HelperLayout` 推导；系统代理写在 App 侧完成（`networksetup` 不需要 root）
- helper **不提供**任意命令执行接口
- 日志用 `os.Logger(subsystem: "com.clash.app", category:)`；secret、订阅 URL 中的 token 需脱敏

## 8. 并发与数据流

- `ClashAPIClient` 是 actor；Helper 客户端是 `@MainActor` 的薄封装 + XPC 回调转 async
- 视图模型 `@Observable @MainActor`；流数据（traffic/logs）用 `AsyncStream` 消费，UI 侧环形缓冲（速率 300 点 / 日志 500 条）
- 单一状态源：`KernelState` 归 `KernelService`；`TrafficBuffer` 归 `TrafficStore`；View 不缓存副本
- 禁止跨 actor 直接改 UI 状态；DTO 全部 `Sendable`

## 9. 测试策略

| 层 | 方式 |
|---|---|
| YAML 注入 | 单测：给定 profile + 设置 → 断言输出键值；覆盖已有键、缺失键、多文档、含锚点 |
| 状态机 | 单测：所有转移 + 崩溃重试上限 |
| 系统代理还原 | 单测（快照 diff）+ 手工：真实切换 Wi-Fi/有线/关闭网络 |
| 内核集成 | 集成测试脚本：起内核 → 打 API → 断言响应 → 停（不依赖外网） |
| UI | 关键路径手工 + 少量快照（面板三种状态） |

## 10. 尚未定（见 `adr/0005`）

- YAML 解析库：`Yams`（建议）vs 零依赖方案
- 分发与更新：ad-hoc 签名 + 用户手动允许（`adr/0008`）；Sparkle 需要签名，v1.0 可能改为手动下载更新
