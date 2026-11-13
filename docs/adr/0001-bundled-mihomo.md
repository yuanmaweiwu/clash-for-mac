# ADR-0001 · 自带 mihomo 内核二进制

- 状态：已接受
- 日期：2026-11-13
- 相关：`docs/01-ARCHITECTURE.md` §1

## 决定

App bundle 内自带 `mihomo` 可执行文件，由 helper 以子进程方式管理；不读取用户机器上已装的 ClashX / 其他客户端。

## 理由

1. **可控**：内核版本、启动参数、配置目录全部由我们决定，出问题能定位到具体版本
2. **体验一致**：用户装完即用，不需要先装别的东西；也不受别家客户端的配置污染
3. **API 契约稳定**：我们只依赖 mihomo 的 RESTful/WS 接口，不依赖其内部实现

## 被否方案

| 方案 | 否决原因 |
|---|---|
| 调用用户已装的 ClashX / mihomo | 路径不固定、版本未知、被卸载就崩；升级不可控 |
| 内嵌内核源码编译成静态库 | 需改写成库形态，GPL 传染范围扩大，维护成本高 |
| 让用户自行放置内核 | 首启门槛高，故障率高 |

## 后果

- 需处理二进制签名（同样用 Hardened Runtime）、架构（arm64 + x86_64 通用二进制）
- 需跟随上游升级；升级节奏由我们自己排，不追最新
- **GPL-3.0 合规**：mihomo 以独立进程调用（非链接），随包提供 `LICENSE` 与源码获取地址；发布页需说明
- 包体积：arm64 单架构约 57MB，DMG 压缩后预计 20MB 左右，待实测
- 内核缺失/签名失败必须在 UI 里有明确错误码，不允许静默启动失败

## 补充 · 版本与架构策略（2026-11-13 用户确认）

- 取上游 **latest release**，不为稳定性锁旧版；风险由「发布前实测 + 可回退」承担
- **仅 arm64**（Apple Silicon）：不做 x86_64、不做 universal。上游 `darwin-arm64-<tag>.gz` 直接用，无需 `lipo`
- 工程侧同步：`ARCHS = arm64`、`ONLY_ACTIVE_ARCH = YES`（Debug），避免产物意外变胖
- Intel Mac 不在支持范围：启动检测到 `x86_64` 直接提示「本应用仅支持 Apple Silicon」
- 可复现性：`Resources/Kernel/VERSION` + `SHA256` 入库，二进制本身不入库
- 升级内核单独一条 commit，message 带版本号；升级后必须跑一遍「启动 → API → TUN 开关 → 停止」

## 补充 · 允许 x86_64 与「内置内核」变体（2026-11-13 用户改变决策）

上面「仅 arm64、不内置内核」两条作废，改为下面这版。

### 架构：arm64 + x86_64

- Release 默认**通用二进制**：`ARCHS = "arm64 x86_64"`、`ONLY_ACTIVE_ARCH = NO`；Helper target 同样通用
- Debug 保持 `ARCHS = arm64` + `ONLY_ACTIVE_ARCH = YES`：本机迭代不为另一架构付编译时间
- 内核按架构选资产：`mihomo-darwin-arm64-<tag>.gz` / `mihomo-darwin-amd64-<tag>.gz`
  （上游后缀是 `amd64`，不是 `x86_64`）
- 校验值**分开存**：`Resources/Kernel/SHA256-arm64` / `SHA256-amd64`。
  两份二进制字节不同，哈希不通用；用错文件会让 Intel 机器永远校验失败
- 地理数据（geoip.metadb / geosite.dat）两个架构共用，不区分
- 校验失败文案必须点明「当前机器架构 x86_64，校验的是 amd64 资产」，否则用户无从判断

### 内置内核变体（可选）

- 构建期开关 `CLASH_BUNDLE_KERNEL=1`：把**当前架构**的 `mihomo` + geodata 拷进
  `Contents/Resources/Kernel/`；不带该变量时包内只有 `VERSION` + 两份 `SHA256-<arch>`
- 运行期不引入标志位文件：`Bundle` 里存在 `Resources/Kernel/mihomo` 就当内置包 ——
  校验 SHA256（同架构）→ 拷到 `~/Library/Application Support/Clash/kernel/`（0755）→ 直接用，
  **不发起任何下载**（geodata 也从包里拷）
- 体积（实测 v1.19.34，arm64）：mihomo 56.7MB + geodata 12.8MB → App 从 15MB 涨到 81MB；
  zip 压缩后 4.1MB → 29MB，即 **+25MB**。单看内核常量是 +56MB，但 geodata 也必须一起进包
- **GPL-3.0 义务回归**：一旦随包分发 mihomo / geodata，就重新承担 GPL 的分发义务 ——
  必须随包提供许可全文（`Clash/Resources/Licenses/GPL-3.0.txt`）与对应源码获取地址
  （`THIRD-PARTY-NOTICES.md` 里带 tag 的上游链接）。只下载不内置时才没有这条义务
- **为什么仍默认不内置**：绝大多数网络下 20MB 按需下载可用；内置版让每个用户都多背 70MB，
  只值得服务「GitHub / 镜像都下不动」的场景。所以它是可选变体，不是默认包

