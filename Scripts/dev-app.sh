#!/usr/bin/env bash
# 构建并启动正式 App（v0.1 起用）。
# 用法：Scripts/dev-app.sh [--build] [--kill]
#   --build  强制重新构建（默认也会构建，只是走增量）
#   --kill   只结束已运行的实例
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="Clash"
APP_NAME="Clash.app"

cd "$ROOT"

if [[ "${1:-}" == "--kill" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || pkill -f "Build/Products/Debug/$APP_NAME" 2>/dev/null || true
  echo "已结束 $(pgrep -x ${APP_NAME%.app} >/dev/null && echo '运行中的实例' || echo '（无运行实例）')"
  exit 0
fi

echo "==> 构建"
xcodebuild -project Clash.xcodeproj -scheme "$SCHEME" -configuration Debug build \
  | tail -3

APP="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -type d -name "$APP_NAME" -path "*/Build/Products/Debug/*" | head -1)"
if [[ -z "$APP" ]]; then
  echo "找不到构建产物，构建可能失败" >&2
  exit 1
fi

echo "==> 产物：$APP"
pkill -f "Build/Products/Debug/$APP_NAME" 2>/dev/null || true
sleep 0.5
open "$APP"
sleep 2
if pgrep -f "Build/Products/Debug/$APP_NAME" >/dev/null; then
  echo "==> 已启动（菜单栏图标可见，无 Dock 图标）"
else
  echo "==> 启动失败，检查 Console.app 中 com.clash.app 的日志" >&2
  exit 1
fi
