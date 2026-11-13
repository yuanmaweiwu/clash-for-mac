#!/usr/bin/env bash
# 把 App 安装到 /Applications（Launchpad 才看得到），并启动。
# 用法：Scripts/install-app.sh [--debug] [--no-launch]
#   默认构建 Release；--debug 用 Debug 产物（更快，但带 .debug.dylib）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="Release"
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="Debug" ;;
    --no-launch) LAUNCH=0 ;;
  esac
done

cd "$ROOT"

if [[ ! -f Resources/Kernel/mihomo ]]; then
  echo "缺少内核，请先运行 Scripts/fetch-kernel.sh" >&2
  exit 1
fi

echo "==> 构建（$CONFIG）"
xcodebuild -project Clash.xcodeproj -scheme Clash -configuration "$CONFIG" build | tail -3

APP="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -type d -name Clash.app -path "*/Build/Products/$CONFIG/*" | head -1)"
[[ -n "$APP" ]] || { echo "找不到构建产物" >&2; exit 1; }

DEST="/Applications/Clash.app"
echo "==> 结束正在运行的实例"
pkill -f 'Clash.app/Contents/MacOS/Clash' 2>/dev/null || true
sleep 1

echo "==> 安装到 $DEST"
if [[ -w /Applications ]]; then
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
else
  echo "/Applications 不可写，请用管理员安装：sudo ditto \"$APP\" \"$DEST\"" >&2
  exit 1
fi

# 让 Launchpad / Spotlight 立即索引（不需要 root）
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

echo "==> 已完成：$DEST"
if [[ $LAUNCH -eq 1 ]]; then
  open "$DEST"
  sleep 2
  if pgrep -f 'Applications/Clash.app/Contents/MacOS/Clash' >/dev/null; then
    echo "==> 已启动（无 Dock 图标，看菜单栏）"
  else
    echo "==> 启动失败，可在「系统设置 → 隐私与安全性」允许后重试" >&2
    exit 1
  fi
fi

echo
echo "提示：这是菜单栏应用，没有窗口也不会出现在 Dock；Launchpad 里能看到图标。"
echo "卸载：rm -rf /Applications/Clash.app（如需同时移除管理员组件，先在设置里点「卸载组件」）"
