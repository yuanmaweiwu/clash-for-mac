# 收尾批（2026-11-14）· 行为 / 健壮性证据

> 基线 `87f22e9` · 构建 `/tmp/dd-last` · 测试数据根一律 `/tmp` 临时目录
> 本批只新增 DEBUG 夹具 / 纯函数判定，未改设置页视图与文案

## 1. 组件安装崩溃（P0）：修复已实测

`9d3c16d` 给 `HelperClient.call` 的两个回调加了 `@Sendable`，但当时没有跑过错误路径。
本批增加 DEBUG 注入点与夹具，用**不存在的 mach service** 触发同一条 errorHandler：

```
CLASH_XPC_ERR_HARNESS=1 \
  /tmp/dd-last/Build/Products/Debug/Clash.app/Contents/MacOS/Clash
```

修复后（当前 HEAD + 本批）：

```
XPC-ERR 连接不存在的 mach service：com.clash.helper.nonexistent
XPC-ERR pid=43213
PASS xpc-error-no-crash 1ms error=helperNotInstalled
exit=0
```

反证（临时删掉 errorHandler 的 `@Sendable`，其余不变）：

```
XPC-ERR 连接不存在的 mach service：com.clash.helper.nonexistent
XPC-ERR pid=42383
exit=133            # SIGTRAP
```

崩溃报告：`~/Library/Logs/DiagnosticReports/Clash-2026-11-14-191724.ips`
（另一次 `Clash-2026-11-14-191803.ips`，pid 42844，栈相同）

```
EXC_BREAKPOINT / SIGTRAP
queue: com.apple.NSXPCConnection.m-user.com.clash.helper.nonexistent
0 _dispatch_assert_queue_fail
2 dispatch_assert_queue
3 swift_task_isCurrentExecutorWithFlagsImpl
4 closure #1 in closure #1 in HelperClient.call<A>(_:)   HelperClient.swift
6 __NSXPCCONNECTION_IS_CALLING_OUT_TO_ERROR_BLOCK__
```

**结论**：`@Sendable` 修复有效；错误回调在 XPC 私有队列执行，不再触发执行器断言。
可复跑：`CLASH_XPC_ERR_HARNESS=1`（Debug）。

## 2. 设置页常驻 +13 MB：属框架缓存，不建议为它重构

夹具：`CLASH_MEMORY_HARNESS=1`（六阶段，每阶段停 6s，供 `vmmap` / `heap` 采样）。

| 阶段 | footprint |
|---|---|
| boot（未开面板） | 13.8 MB |
| 打开面板（root） | 25.6 MB |
| 进设置页 | 38.2 MB |
| 返回 root | 38.5 MB |
| 收起面板 | 39.8 MB |
| 丢掉整棵 SwiftUI 树 | 37.4 MB（−2.3） |
| `malloc_zone_pressure_relief` | 35.1 MB（再 −2.3） |

`vmmap -summary`（面板 → 设置）dirty 增量 ≈ +12.3 MB：
`MALLOC_TINY +4.9M`、`MALLOC_SMALL +3.3M`、`MALLOC_MEDIUM +0.5M`、
`CoreServices +1.5M`、`CoreUI image data +0.7M`、`AttributeGraph +0.2M`、`CoreAnimation +0.2M`。

`heap --forkCorpse -s`：设置页的**存活对象反而更少**（15.97 MB → 13.64 MB）；
丢掉 SwiftUI 树后 `LayoutEngineBox`、`DisplayList.Item`、`NSCTFont` 等布局/字体对象归 0，
但 footprint 仍比打开设置前高 ≈ 9.5 MB。

**结论**：+13 MB 不是我们的数据，也不是未释放的视图对象，而是 AppKit/SwiftUI 一次性
控件/字体/布局+分配器页缓存。释放整棵树 + malloc 回收只能拿回约 4.6 MB（35%），
代价是每次开面板都重建视图树（首帧、滚动位置、动画状态都有回归风险）。
**不建议为 4 MB 重构路由 / 改系统 `Picker` 控件**；保留现状，已用数据量化。

## 3. A7：helper 启动回收孤儿（运行路径仍未实测）

原有 `CLASH_HELPER_SELFCHECK` 只覆盖配置新鲜度；本批把孤儿判据抽成纯函数
`KernelOrphanReaper.shouldReap(candidatePID:parentPID:executablePath:selfPID:kernelToolPath:)`，
`reapOrphans()` 改为调用它（行为不变）。代码路径：`Helper/main.swift:15`
在挂 XPC 监听之前 `KernelOrphanReaper.reapOrphans()`。

```
CLASH_HELPER_SELFCHECK=1 \
  /tmp/dd-last/Build/Products/Debug/Clash.app/Contents/Library/PrivilegedHelperTools/com.clash.helper
```

```
SELFCHECK shouldRestartKernel 判定表
PASS 配置比进程新 1s：expected=true actual=true
PASS 配置比进程新 0.5ms：expected=false actual=false
PASS 配置与进程同时：expected=false actual=false
PASS 配置比进程旧 10s：expected=false actual=false
SELFCHECK KernelOrphanReaper.shouldReap 判定表
PASS 同路径、非子进程 → 回收：expected=true actual=true
PASS 路径带冗余斜杠 → 回收：expected=true actual=true
PASS 候选就是自己 → 不回收：expected=false actual=false
PASS 候选是自己的子进程 → 不回收：expected=false actual=false
PASS 路径不同（别家内核）→ 不回收：expected=false actual=false
PASS 取不到路径 → 不回收：expected=false actual=false
SELFCHECK DONE failures=0
```

**限制**：需要 root 重启 helper（`launchctl kickstart -k system/com.clash.helper`）才能观察
真实回收；本批**未实测运行路径**，只证明判据与调用顺序。

## 4. A6：TUN 预检旧内核（真 helper 实测）

临时数据根 `/tmp/clash-b1-root`（复制 `settings.json` / `profiles/` / geodata，不碰真实目录）：

```
CLASH_DATA_ROOT=/tmp/clash-b1-root CLASH_AUDIT_B1=1 \
  /tmp/dd-last/Build/Products/Debug/Clash.app/Contents/MacOS/Clash
```

```
B1 TUN ON oldPid=45363
B1 失忆后 phase=off helperPid=45363
B1 重开完成 用时=0.50s oldPid=45363 newPid=45384 version=v1.19.34
B1 DONE failures=0
```

`/Library/Application Support/ClashHelper/helper.log`：

```
11:24:53.320 以 root 启动内核 pid=45363
11:24:53.775 内核已停止（确认退出）
11:24:53.775 stopKernel → 已确认退出
11:24:53.827 运行配置已更新 53861 bytes
11:24:53.828 以 root 启动内核 pid=45384
```

旧内核在重开前 52ms 内被停掉并换新 pid，未出现 8s 超时；夹具收尾把 root 内核停干净
（`7890` 释放、无 mihomo 进程）。

## 5. 构建与单测

- `xcodebuild -configuration Debug|Release`：**0 warning**
- `bash Scripts/unit-tests.sh`：**95/95**
- 设置页截图（Debug 夹具）：四项 `Picker`、开关、返回、清理入口均在，视图与文案未改
