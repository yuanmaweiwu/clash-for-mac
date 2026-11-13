---
name: system-proxy
description: "系统代理（networksetup）开关与安全还原的唯一约定：服务枚举、快照结构、开启/关闭/回滚流程、崩溃与卸载兜底、端口联动、验证命令。凡涉及「开代理/关代理」、系统网络设置写入、代理残留排查时加载。触发词：系统代理、system proxy、networksetup、webproxy、SOCKS、快照、还原、残留、断网。"
---

# 系统代理：开关与安全还原

> 进程与权限模型见 [`docs/01-ARCHITECTURE.md`](../../../docs/01-ARCHITECTURE.md) §6 §7；内核端口见 `core-process` §4。
> **本技能的最高优先级不是「能开」，而是「一定能还原」。** 残留代理 = 用户全机断网，属于最严重故障。

## 1. 硬边界

- `networksetup` 只能在 **helper（root）** 里执行；App 侧一律经 XPC 请求
- 禁止 App 直接 `Process` 跑 `networksetup`
- 禁止在未写快照的情况下修改任何代理项
- 禁止只处理 Wi-Fi：必须遍历全部启用的网络服务（Wi-Fi / 以太网 / Thunderbolt / iPhone USB …）

## 2. 服务枚举

```bash
networksetup -listallnetworkservices
```

输出首行是说明文字（`An asterisk (*) denotes that a network service is disabled.`），后续每行一个服务名；**以 `*` 开头的跳过**（已禁用服务不需要改）。

注意：

- 服务名含空格与中文（如「USB 10/100/1000 LAN」），传参必须逐参数引用，不要拼成一整串
- 不要缓存服务列表跨会话使用；网络变化（插网线、开热点）后重新枚举
- 顺序无关，但快照要记录服务名，还原按名匹配

## 3. 快照（唯一真相）

写入 `~/Library/Application Support/Clash/systemproxy-snapshot.json`，原子写（临时文件 + rename）。

```json
{
  "version": 1,
  "createdAt": "2026-11-13T06:12:00Z",
  "kernelPort": 7890,
  "services": [
    {
      "name": "Wi-Fi",
      "web":    { "enabled": false, "server": "", "port": 0 },
      "secure": { "enabled": false, "server": "", "port": 0 },
      "socks":  { "enabled": false, "server": "", "port": 0 },
      "auto":   { "enabled": false, "url": "" },
      "bypass": ["*.local", "169.254/16"]
    }
  ]
}
```

采集命令（每服务一项）：

```bash
networksetup -getwebproxy "Wi-Fi"
networksetup -getsecurewebproxy "Wi-Fi"
networksetup -getsocksfirewallproxy "Wi-Fi"
networksetup -getautoproxyurl "Wi-Fi"
networksetup -getproxybypassdomains "Wi-Fi"
```

解析要点：输出是 `Enabled: Yes|No` / `Server: x` / `Port: n` 这类行；`bypass` 在未设置时输出 `There aren't any bypass domains set on <service>.`，此时记为空数组。

## 4. 开启流程（顺序不可换）

```
1 枚举服务 → 2 采集全部项 → 3 原子写快照 → 4 逐项设置 → 5 校验读回 → 6 回报成功
```

```bash
networksetup -setwebproxy         "<service>" 127.0.0.1 <port>
networksetup -setsecurewebproxy   "<service>" 127.0.0.1 <port>
networksetup -setsocksfirewallproxy "<service>" 127.0.0.1 <port>
networksetup -setautoproxystate   "<service>" off
```

- 快照写盘 **先于** 第一次写入；写盘失败就整体放弃，不要「先改再说」
- 设置完逐个 `-getwebproxy` 读回校验；任一服务失败 → 立刻按快照全量还原 → 返回失败（不要留下半开状态）
- 只在用户开启「SOCKS」时设 socks；默认 HTTP/HTTPS 都指向 `mixed-port`
- **不要**设置 `-setautoproxyurl`（PAC），v1 不做 PAC

## 5. 关闭流程

```
1 读快照 → 2 逐项还原（关闭项就 setstate off，启用的项写回原 server/port）→ 3 读回校验 → 4 删除快照
```

- 还原必须**逐服务逐项**执行，不能只 `-setwebproxystate off`：用户原本可能自己配了代理，off 会抹掉他的设置
- 快照里 `enabled: false` 的项 → `-setwebproxystate <service> off`（secure/socks 同理）
- `enabled: true` 的项 → 按原 server/port 重新写回
- 全部成功后才删快照；有一项失败保留快照并报错，供下次重试

## 6. 崩溃 / 异常 / 卸载兜底

| 场景 | 处理 |
|---|---|
| App 崩溃 | 内核与代理状态不受影响（helper 持有）；下次 App 启动读状态 |
| helper 崩溃 | 系统自动重启 daemon；启动时检查：快照存在 且 内核未运行 → 立即还原 |
| 内核崩溃重试失败 | 先还原系统代理，再回报失败（不要让用户对着一个死内核被代理） |
| 用户注销 / 重启 | daemon 启动时同上检查 |
| 卸载 | 设置里「完全清理」：还原代理 → 停内核 → 注销 daemon → 删配置目录 |

兜底判定的核心不变式：**「快照存在」⟺「我们改过系统代理且尚未还原」**。任何路径看到快照但内核不可用，都应还原而不是继续等待。

## 7. 与端口的联动

- 端口从设置里改了 → 若代理正开着：先还原 → 用新端口重开 → 刷新快照里的 `kernelPort`
- 内核重启若换了端口（不应发生，端口固定）→ 同上
- 面板显示「代理中」的唯一判据：内核 `running` **且** 系统代理读回校验通过

## 8. 验证与排障

```bash
# 看当前状态（应与面板一致）
networksetup -getwebproxy "Wi-Fi"
networksetup -getsecurewebproxy "Wi-Fi"
networksetup -getsocksfirewallproxy "Wi-Fi"

# 探测代理是否真的通（直连本地端口，不走代理）
curl -sS -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204
```

| 现象 | 常见原因 |
|---|---|
| 面板显示已开，浏览器不走代理 | 改的是另一个网络服务；或 SOCKS 未设；或 App 自带代理设置覆盖 |
| 关代理后仍上不了网 | 快照缺失/损坏；用 `-setwebproxystate off` 全套关闭临时恢复，再排查 |
| 只有部分 App 受影响 | 该 App 用了独立代理配置或 PAC |
| 每次都要输密码 | 说明有代码在 App 侧调 `networksetup`，未走 helper |

## 9. 反模式

- ❌ 先改后存快照
- ❌ 只处理 Wi-Fi
- ❌ 关闭时一律 `setstate off`（抹掉用户原有代理）
- ❌ 用 `networksetup -setairportpower` 等无关命令「顺便」修网络
- ❌ 把服务名写死（"Wi-Fi" 在部分机器叫 "Wi-Fi 2"）
- ❌ 静默失败：读回校验不通过必须上报，不要 `try?`

## 10. 自检清单

- [ ] 修改前快照已原子落盘，包含全部启用服务
- [ ] 关闭路径逐项还原，不是整体 off
- [ ] 读回校验通过才算成功；失败有回滚
- [ ] helper 启动路径含「快照存在但内核不可用 → 还原」
- [ ] 端口变更后会等比刷新代理
- [ ] 面板「代理中」判据 = 内核 running + 读回校验通过
- [ ] 卸载/完全清理有还原步骤
