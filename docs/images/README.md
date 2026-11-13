# 截图（README 引用）

## 内容

| 文件 | 内容 |
|---|---|
| `hero.png` | 菜单栏 + 展开的面板（用于 README 顶部） |
| `panel-idle.png` | 内核未运行（340 × 496） |
| `panel-ready.png` | 内核已运行、未接管流量（340 × 496） |
| `panel-nodes.png` | 真实策略组与节点（340 × 496） |

## 规则（重要）

1. **只放真实运行截图**，不要用 `Prototype/` 的离屏渲染图代替——原型只是设计验证，README 必须反映真实 App。
2. **不允许出现个人隐私**：真实节点名、机场域名、订阅链接、token、单号、流量余额一概不能进图。测试请用 `TEST-SS-*` / `测试选择` 这类假数据。
3. 面板固定 340pt 宽；`hero` 保留菜单栏一行作为上下文。
4. 主题跟随系统，截图时不要临时改系统外观（避免半深半浅）。
5. 新增状态按 `panel-<状态>.png` 命名（如 `panel-failed.png`、`panel-subscriptions.png`），README 引用相对路径 `docs/images/<name>.png`。

## 更新方式

```bash
Scripts/dev-app.sh                 # 构建并启动（无 Dock 图标，看菜单栏）
# 点菜单栏图标展开面板后：
screencapture -x -o -l<窗口 ID> docs/images/panel-<状态>.png
```

窗口 ID 取法：`swift` 脚本列 `CGWindowListCopyWindowInfo`，挑 owner 是 Clash、尺寸 340×496 的那个；面板会随焦点关闭，所以「点击 → 截图」要在同一条命令里连续做完。
