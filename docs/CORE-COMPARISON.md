# 运行时开销对比：Clash（本项目）vs Clash Verge

> 机型：Mac mini M4 · macOS 15.7.7 · 2026-11-14
> 方法：`ps` 每 30s 采样 RSS/CPU；`footprint` 取活动监视器口径（按进程）；`netstat` 校验 TUN 路由（`128.0/1 → utun4`）
> 注意：两者架构不同（原生 SwiftUI vs Tauri + WKWebView），下表**只比数字，不做优劣结论**。

## 1. 进程构成（为什么 Verge "只有 28MB"）

`footprint` 是**每进程**的值。Verge 由 5 个进程组成，单个壳很小，总量在别处：

| Verge 进程 | footprint | RSS |
|---|---|---|
| `clash-verge`（Tauri 主进程） | 37–38 MB | 114 MB |
| `verge-mihomo`（内核，root） | 读不到（root 保护） | 66 MB |
| `clash-verge-service`（root） | 读不到 | 8 MB |
| WebKit.GPU | 85–184 MB | 105 MB |
| WebKit.WebContent | 108–116 MB | 235–268 MB |
| WebKit.Networking | 小 | 16 MB |

本项目只有 1 个 GUI 进程（内核独立）：

| 我们的进程 | footprint | RSS |
|---|---|---|
| `Clash` | **31–33 MB** | 109 MB |
| `mihomo`（本地/root 视模式） | 本地 41 MB / root 读不到 | 55–64 MB |
| `com.clash.helper` | — | 11 MB |

## 2. 空闲（内核运行、代理关、TUN 关）

| 指标 | 本项目 | Clash Verge（窗口开） |
|---|---|---|
| GUI 进程 footprint | **31 MB** | 37 MB |
| 全进程 RSS 合计 | 约 160 MB | 约 580 MB |
| CPU | ≈0.1% | ≈2–4% |

## 3. TUN 开启（5 分钟 / 10 分钟）

| 指标 | 本项目（5 min） | 本项目（10 min） | Verge（5 min） | Verge（10 min） |
|---|---|---|---|---|
| RSS 合计 | 157–158 MB | 161.7–161.9 MB | 578–584 MB | 584.7–586.0 MB |
| RSS 增长 | +0.9 MB | **+0.2 MB** | +6.7 MB | **+1.3 MB** |
| CPU 均值 | ≈0.3% | ≈0.5% | ≈4.4% | ≈3.3% |
| CPU 峰值 | 1.0% | 3.7%（开启瞬间） | 9.6% | 7.8% |
| TUN 路由 | 全程 `128.0/1` | 同 | 同 | 同 |

## 4. 反复开关 TUN（各 5 次）

| 指标 | 本项目 | Verge |
|---|---|---|
| GUI footprint 前后 | 33 MB → 33 MB | 38 MB → 38 MB |
| WebKit GPU | —（无 WebView） | 183 MB → 183 MB |
| WebKit WebContent | — | 114 MB → 114 MB |
| 路由清理 | 5 次后 `128.0/1` 归 0 | 同 |
| 泄漏迹象 | 无 | 无（WebKit 表面不涨） |

## 5. 结论

1. **差距的主因是 WebView**：Verge 的 WKWebView 三个进程合计约 300 MB footprint，是它的固定成本；本项目没有 WebView。
2. **TUN 模式下我们更轻**：全进程 RSS 约 160 MB vs 580 MB；CPU 均值 0.5% vs 3.3%。
3. **两边都没有明显泄漏**：10 分钟 TUN 增长分别 +0.2 MB 与 +1.3 MB，属于缓存量级；反复开关 5 次 footprint 不涨。
4. 我们的内存优化（`3285082`）之后，GUI 自身 31–33 MB，已低于 40 MB 目标。

## 6. 局限

- `footprint` 对 root 进程（两边内核与 service）读不到，只能用 RSS 近似
- WebKit 进程在 Verge 窗口关闭时才退出，本轮 Verge 测试全程开窗，属"有界面"对照
- CPU 为 `ps` 采样近似值，不是 Instruments 级；两者不同语言运行时（Swift vs Rust/JS）冷热路径不同
- Verge 的 TUN 会替换其内核为 root 版本；本项目 TUN 也切换为 root 内核，故两边该模式下都含一份 root 内核
