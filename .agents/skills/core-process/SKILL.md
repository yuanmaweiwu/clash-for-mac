---
name: core-process
description: "Clash 内核（mihomo）相关工作的唯一约定源：二进制获取与版本策略、helper 进程管理、运行配置注入、RESTful/WebSocket API 契约、错误分类与排障。凡涉及启动/停止内核、读写 /configs、节点与延迟、traffic/logs 流、TUN 参数、内核升级时加载。触发词：mihomo、内核、core、external-controller、proxies、traffic、TUN、helper、XPC、runtime config。"
---

# Clash 内核（mihomo）：进程与 API

> 上层架构见 [`docs/01-ARCHITECTURE.md`](../../../docs/01-ARCHITECTURE.md)；决策见 ADR-0001 / 0004。
> 本技能只管「怎么和内核对」。UI 规范看 `docs/02-UI-SPEC.md`，分层看 `architecture`。

## 1. 二进制与版本策略

- 来源：上游 `MetaCubeX/mihomo` 的 **latest release**（用户已确认「取上游最新」）
- **arm64 + amd64**：按当前机器架构取 `mihomo-darwin-arm64-<tag>.gz` / `mihomo-darwin-amd64-<tag>.gz`（排除 `-go1xx` 变体）
- 获取脚本：`Scripts/fetch-kernel.sh`（两个架构都拉 → 解压 → `lipo -archs` 校验 → 写 `VERSION`、`SHA256-arm64` / `SHA256-amd64`，并暂存到 `.stage/` 供打包）；已实测 v1.19.34
- **二进制不入库**（约 57MB）：`.gitignore` 忽略，`VERSION` / `SHA256` 入库；构建前必须先跑脚本
- 工程侧：Release `ARCHS = (arm64, x86_64)`、`ONLY_ACTIVE_ARCH = NO`；Debug 单架构；`CLASH_BUNDLE_KERNEL=1` 时把内核打进包
- 每次发布前必须记录当时版本与 sha256；升级内核 = 单独一条 commit（`升级 `mihomo` 内核到 vX.Y.Z`）
- 签名：与应用同 profile、Hardened Runtime；helper spawn 前先校验 `codesign` 与 bundle 路径，不通过直接失败并给错误码
- GPL-3.0：`Resources/Kernel/LICENSE` 与源码地址随包分发

## 2. 进程模型（只许这一种）

```
App ──XPC──► helper(root) ──posix_spawn──► mihomo
```

- App **禁止**直接 `Process` 启动 mihomo
- helper 是唯一持有内核句柄者；App 只拿到「状态 + 端口 + secret」
- 系统代理模式：以登录用户 uid/gid 降权启动（`posix_spawnattr_setuid_np` / `setgid_np` + `POSIX_SPAWN_SETUID` / `SETGID`）；TUN 模式：root 启动
- 降权时需要补 `setgroups` 时，不要硬塞进 spawn attr，改用一个极小的 setuid 包装（或先 `chown` 配置目录再以用户身份写）；**不要**让 root 内核直接写用户目录
- 停止：先 `SIGTERM`，等 3s，再 `SIGKILL`；端口释放后再回报 `stopped`
- 单实例保护：helper 内维护 pid + 启动时间戳；重复 `start` 返回既有实例，不重复 spawn
- **孤儿清理**：App 被 `SIGKILL` / 系统强杀时子进程会残留。`start()` 前必须用 `libproc`（`proc_listallpids` + `proc_pidpath`）找出**本产品内核**：路径以 `/Clash.app/Contents/Resources/Kernel/mihomo` 结尾（`KernelProcessIdentity`），覆盖 DerivedData / `/Applications` / 任意副本；`SIGTERM` → 2s → `SIGKILL`，再启动；**禁止按进程名或 `contains("Clash")` 模糊匹配**（会误杀 ClashX、Clash Verge 等）。helper 的 `/Library/PrivilegedHelperTools/mihomo` 只检测、不 kill（root）
- 启动前确认 `mixed-port` 空闲；被占则 `lsof -nP -iTCP:<port> -sTCP:LISTEN` 查出 pid + 名称，报 `portInUse`（文案带占用者），不要硬起（两个内核抢同一端口时行为不可预测）。占用者若是本产品内核 → 回收后**自动重试一次**；别家进程则留给用户
- 崩溃重试：非用户停止的退出 → 最多 3 次（1s / 3s / 9s 退避）；仍失败则锁定为 `failed` 并上报 exit code + 最后 20 行日志

## 3. 目录布局

```
~/Library/Application Support/Clash/
├── settings.json           应用设置（原子写）
├── profiles/<id>.yaml      用户配置，原样保存，永不改写
├── profiles/index.json     订阅库索引：activeProfileID、每条 name/source/updatedAt/autoUpdateHours/lastError/subscriptionInfo/pinnedGroups
├── kernel/                 内核共享工作目录（`-d`）：geoip.metadb、cache.db、geosite
├── runtime/<id>.yaml       每次启动重建的最终配置
├── logs/clash-YYYYMMDD.log
└── systemproxy-snapshot.json
```

- 所有写入走「临时文件 + `rename`」原子替换
- 除 `settings.json` 外不做跨版本迁移；profiles 只增不改
- **同一时刻只有一条 active**：切换 = 改 `activeProfileID` → 重建 runtime → `PUT /configs?force=true`
- `pinnedGroups` / 上次选中等 UI 偏好只存 index 或 settings，**不注入** runtime，也不触发重载

## 4. 运行配置注入（最小集合）

在解析后的顶层键上覆盖，然后整体写出；**禁止字符串拼接**。

| 键 | 来源 | 说明 |
|---|---|---|
| `mixed-port` | 设置（默认 7890） | 主入口 |
| `port` / `socks-port` | 设置（可关） | 不需要就删除该键 |
| `allow-lan` | 设置（默认 false） | 只影响代理端口 |
| `mode` | 面板当前模式 | `rule` / `global` / `direct` |
| `log-level` | 设置 | 默认 `info` |
| `external-controller` | **固定 `127.0.0.1`** + 随机空闲端口 | 禁止 `0.0.0.0` |
| `dns.listen` | `127.0.0.1` + 随机空闲端口 | 真实订阅常带 `0.0.0.0:1053`，必须收紧 |
| `bind-address` | `127.0.0.1` | 与 `allow-lan: false` 配套 |
| `secret` | 每次启动随机 32 字节（内存持有） | 禁止写日志 |
| `tun.*` | TUN 开关 | 见 §6 |

生成后先 `mihomo -t -d <sharedDir> -f <runtime>` 校验，失败不进 `starting`（退出码 0/1 可靠，别解析 stderr 文本）。

**`-d` 目录全 profile 共用一个**：首次运行会下载 `geoip.metadb`（约 8MB）到 `-d` 目录；按 profile 分开会让每份订阅各下一份。
首次启动需要网络（`Can't find MMDB, start download`）；离线首启要能给出「正在准备地理数据」而不是「配置无效」。

**TUN / helper 的 `-d` 是 root 目录**（`/Library/Application Support/ClashHelper`）：geodata 只在安装脚本里从用户内核目录拷入一次，运行期不会再同步。订阅后来才需要 GeoSite（规则 `GEOSITE,` 或 DNS 策略 `'geosite:cn'` 冒号形式）时，root 内核找不到 `geosite.dat` 就会尝试在线下载 → 国内超时 → 表现为「8 秒内未就绪」。修复只有一条路：重装组件（重新拷入），不要给 helper 加写盘接口。

订阅更新时同样用临时 runtime 校验，通过后才原子替换 `profiles/<id>.yaml`；失败保留旧文件并只写 `lastError`。
`subscription-userinfo` 响应头（`upload/download/total/expire`）解析进 index，缺字段留空。

## 5. API 契约（只依赖这些）

Base：`http://127.0.0.1:<port>`，头 `Authorization: Bearer <secret>`。

| 用途 | 请求 | 备注 |
|---|---|---|
| 连通性 | `GET /version` | 返回 `version`、`meta`；面板展示用 |
| 读配置 | `GET /configs` | 端口、模式、TUN 状态 |
| 热改 | `PATCH /configs` `{"mode":"global"}` | 只改运行时，不落盘 |
| 重载 | `PUT /configs?force=true` `{"path":"<runtime>"}` | 配置切换 |
| 全部代理 | `GET /proxies` | `proxies{name:{type,now,all,history,udp,alive}}` |
| 选择 | `PUT /proxies/{name}` `{"name":"<节点>"}` | 组名 URL 编码 |
| 单测速 | `GET /proxies/{name}/delay?timeout=5000&url=http://www.gstatic.com/generate_204` | 返回 `delay` 或错误 |
| 组测速 | `GET /group/{name}/delay?url=...&timeout=` | 结果以名字为键 |
| 规则 | `GET /rules` | 只读展示 |
| 连接 | `GET /connections` | 也支持 WS 推送 |
| 关连接 | `DELETE /connections` / `DELETE /connections/{id}` | |
| 速率 | `GET /traffic`（WS） | 逐秒 `{up,down}`，字节/秒 |
| 日志 | `GET /logs?level=info`（WS） | `{type,payload}` |
| 内存 | `GET /memory`（WS） | 可选 |

WS 连接：`ws://127.0.0.1:<port>/traffic?token=<secret>`（或用 Bearer 头）。

约定：

- 全部经 `ClashAPIClient`（actor）；其他模块禁止直接 `URLSession`
- 超时：普通 5s，测速按请求的 `timeout` 再加 2s
- 断线重连：1s→2s→4s→8s 封顶；重连期间 UI 标「数据暂停」，**不清零**已有曲线
- 端口 / secret 变更后必须重建客户端与 WS，不复用旧连接

## 6. TUN

```yaml
tun:
  enable: true
  stack: gvisor          # 兼容性优先；system 更快但依赖系统栈
  auto-route: true
  auto-detect-interface: true
  dns-hijack: ["any:53"]
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
```

- TUN 必须 root；helper 未安装 / 未批准时**不要**尝试启动，直接给引导
- 开启前检查已有 utun / 其它 VPN 工具；冲突时提示并回退系统代理模式
- 关闭后确认默认路由与 DNS 复原；异常时提示「需要重连网络」
- 关闭顺序：先停内核，再确认路由 → 减少「断网残留」

## 7. 错误分类（UI 必须能区分）

| 类别 | 判定 | 用户侧动作 |
|---|---|---|
| `binaryMissing` | 包内无 mihomo / 权限不对 | 重装应用 |
| `binaryRejected` | 签名校验失败 | 重装应用（不要建议改 Gatekeeper） |
| `configInvalid` | `-t` 非 0 | 打开配置文件 / 换配置 |
| `portInUse` | 绑定失败（address already in use）；文案带占用者 pid / 名称 | 本产品内核 → 自动回收重试；别家 → 去设置改端口 |
| `helperNotInstalled` | XPC 连接失败 | 引导安装 helper |
| `permissionDenied` | 授权被拒 | 系统设置 → 登录项与扩展 |
| `crashed` | 非预期退出 | 展示 exit code + 重试按钮 |

日志脱敏：secret、订阅 URL 的 `token`/`key` 参数一律打码。

## 8. 自检清单

- [ ] 没有绕过 `ClashAPIClient` 直接发请求
- [ ] 没有改写 `profiles/*.yaml`
- [ ] 没有把 `external-controller` 设成 `0.0.0.0`
- [ ] secret 未落盘、未进日志
- [ ] 停止路径先 SIGTERM 后 SIGKILL，且确认端口释放
- [ ] TUN 关闭后路由/DNS 复原已验证
- [ ] 新错误都归入 §7 的某一类，并有中文文案
