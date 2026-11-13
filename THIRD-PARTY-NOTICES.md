# 第三方组件与许可

本项目的客户端代码以 [MIT](./LICENSE) 发布。随包分发的第三方组件如下，各自保留其原始许可。

## 运行时组件（随 App 分发）

| 组件 | 版本 | 许可 | 上游 | 分发形式 |
|---|---|---|---|---|
| mihomo | v1.19.34 | **GPL-3.0** | https://github.com/MetaCubeX/mihomo/tree/v1.19.34 | 独立进程（`Contents/Resources/Kernel/mihomo`，TUN 模式由特权组件运行） |
| geoip.metadb / geosite.dat | latest（构建时拉取） | **GPL-3.0** | https://github.com/MetaCubeX/meta-rules-dat | 数据文件，与内核同目录 |
| Yams | 5.4.0 | **MIT** | https://github.com/jpsim/Yams | 静态链接进 App（唯一 Swift 依赖） |

许可全文见 [`Clash/Resources/Licenses/`](Clash/Resources/Licenses/)：`GPL-3.0.txt`、`yams-MIT.txt`。

### GPL-3.0 合规说明

- mihomo 与 geodata 均以 **GPL-3.0** 分发。本项目对其**不做修改**，二进制与数据直接取自上游发布版本。
- 对应源码：mihomo `v1.19.34`（见上表链接）；geodata 由 `MetaCubeX/meta-rules-dat` 生成，仓库同上。
- 内核以**独立进程**方式调用，不与客户端代码链接，属于 GPL 意义上的聚合（aggregation）；因此客户端代码可以独立以 MIT 发布。
- 未对内核做签名校验或路径锁定：用户可自行替换 `mihomo` 二进制（自行承担风险），不存在阻止替换的附加限制。

## 仅用于构建/发布（不随包分发）

| 组件 | 许可 | 用途 |
|---|---|---|
| actions/checkout、actions/cache、actions/upload-artifact、softprops/action-gh-release | MIT | GitHub Actions |
| Swift / SwiftUI / AppKit / SF Symbols | Apple SDK 协议 | 系统框架 |

## 系统服务

- 开机自启使用 `SMAppService`；TUN 使用自建 LaunchDaemon（`com.clash.helper`），不包含第三方代码。
