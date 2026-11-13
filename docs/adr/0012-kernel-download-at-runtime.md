# ADR-0012 · 内核与 geodata 改为运行时下载

- 状态：已接受
- 日期：2026-11-13
- 相关：`adr/0001`（内置内核，已被本 ADR 取代分发方式）、`docs/01-ARCHITECTURE.md` §4

## 决定

App 包内**不再包含** `mihomo` / `geoip.metadb` / `geosite.dat`，只保留 `Resources/Kernel/VERSION` 与 `SHA256`。首次需要内核时（启动内核、点「连接」、开启 TUN、导入订阅校验）由 App 下载到 `~/Library/Application Support/Clash/kernel/`，校验 SHA256 后 `chmod 0755` 再继续。

TUN 的特权组件安装脚本不再从 bundle 拷贝内核：改为从上述用户目录拷 `mihomo` 与 geodata 到 `/Library/PrivilegedHelperTools/mihomo` 与 `/Library/Application Support/ClashHelper`。路径在生成脚本时用 `NSHomeDirectory()` 拼好写死，脚本仍不接受参数。

## 下载源策略（三档，设置里可选）

| 模式 | 行为 |
|---|---|
| 自动（默认） | 依次尝试 直连 → `https://gh-proxy.com/` → `https://ghproxy.net/`，每个约 10 秒；成功一个即停 |
| 仅直连 | 只走 `https://github.com/...` 原始地址 |
| 自定义 | 用户填的前缀 + 原始 GitHub URL，原样拼接，不做改写 |

镜像清单集中在 `Core/Services/KernelDownloadMirrors.swift`：都是**第三方服务**，可能失效，可随时增删。`geodata` 使用同一策略；`geoip.metadb` 必需，`geosite.dat` 失败只告警。

## 为什么默认用第三方镜像也安全

每个源下载完都必须与 committed 的 `Resources/Kernel/SHA256` 一致；`gunzip` 后校验，不匹配立即删除并换下一个源。镜像只能转发字节，无法替换内核内容。这条不变量写进了 `KernelProvisioner` 的注释与 README。

## 失败与重试

- 分类：网络不可达 / HTTP 非 2xx / 校验失败 / 解压失败 / 磁盘写入失败；全部源失败时文案「所有下载源均不可达，可在设置里换镜像后重试」
- 不静默回退到「没有内核」：启动停在 `failed` 并给出可操作原因，用户可直接重试
- 落地先写 `.tmp` 再 rename；任何失败路径都删除 `.tmp` / `.gz`，不留半截文件
- 同一时刻只允许一个下载任务（`KernelProvisioner` 串行化）；不做断点续传

## 被否方案

| 方案 | 否决原因 |
|---|---|
| 继续内置二进制 | 包体积约 57MB；内核升级必须重发整个 App；Linux/CI 构建对二进制依赖重 |
| 让用户手动下载 | 首启门槛高、路径容易放错，失败率高 |
| 只直连 GitHub、不提供镜像 | 这台机器实测官方直连超时；国内网络下首次使用大概率失败 |
| 镜像内容不做校验 | 第三方镜像可篡改二进制；哈希校验是使用镜像的前提 |

## 后果

- 首次需要内核时必须联网（约 20MB gz）；离线环境需提前用 `Scripts/fetch-kernel.sh` 预置
- GitHub 与第三方镜像都可能不可达：设置里保留自定义前缀作为兜底
- 内核升级不再需要重发 App，但 `VERSION` / `SHA256` 仍需随版本提交
- 不随包分发 mihomo / geodata，因此不承担 GPL-3.0 的分发义务；应用内仍提供许可全文与源码链接（`THIRD-PARTY-NOTICES.md`）
- 内核进程路径变为 `~/Library/Application Support/Clash/kernel/mihomo`：孤儿回收与端口占用判据同步更新
