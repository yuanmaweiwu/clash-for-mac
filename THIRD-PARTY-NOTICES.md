# 第三方组件与许可

本项目的客户端代码以 [MIT](./LICENSE) 发布。第三方组件与分发方式如下，各自保留其原始许可（内核与 geodata 改为运行时下载，见 ADR-0012）。

## 运行时组件（首次使用时下载，不随包分发）

| 组件 | 版本 | 许可 | 上游 | 分发形式 |
|---|---|---|---|---|
| mihomo | v1.19.34 | **GPL-3.0** | https://github.com/MetaCubeX/mihomo/tree/v1.19.34 | 独立进程；首次需要时下载到 `~/Library/Application Support/Clash/kernel/mihomo`，TUN 模式由特权组件运行 |
| geoip.metadb / geosite.dat | latest（运行时拉取） | **GPL-3.0** | https://github.com/MetaCubeX/meta-rules-dat | 数据文件，与内核同目录（`kernel/`） |
| Yams | 5.4.0 | **MIT** | https://github.com/jpsim/Yams | 静态链接进 App（唯一 Swift 依赖） |

许可全文见 [`Clash/Resources/Licenses/`](Clash/Resources/Licenses/)：`GPL-3.0.txt`、`yams-MIT.txt`。

### GPL-3.0 合规说明

- mihomo 与 geodata 均为 **GPL-3.0**。**本项目不随安装包分发它们**：首次需要内核时由 App 从上游 GitHub release 下载，因此不承担 GPL-3.0 的分发义务。
- 应用内仍提供 GPL-3.0 许可全文与上游源码地址；内核仍为 GPL-3.0，用户可自行替换下载后的二进制。
- 对应源码：mihomo `v1.19.34`（见上表链接）；geodata 由 `MetaCubeX/meta-rules-dat` 生成，仓库同上。
- 下载内容通过 `Resources/Kernel/SHA256` 校验；默认镜像只转发字节，无法替换内核。
- 内核以**独立进程**方式调用，不与客户端代码链接，属于 GPL 意义上的聚合（aggregation）；因此客户端代码可以独立以 MIT 发布。

## 仅用于构建/发布（不随包分发）

| 组件 | 许可 | 用途 |
|---|---|---|
| actions/checkout、actions/cache、actions/upload-artifact、softprops/action-gh-release | MIT | GitHub Actions |
| Swift / SwiftUI / AppKit / SF Symbols | Apple SDK 协议 | 系统框架 |

## 系统服务

- 开机自启使用 `SMAppService`；TUN 使用自建 LaunchDaemon（`com.clash.helper`），不包含第三方代码。
