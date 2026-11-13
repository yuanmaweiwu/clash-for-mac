#!/usr/bin/env bash
# 用真实 App 的 Debug 产物截一张面板 / 日志窗口的图（真材质 + 真壁纸）。
#
# 用法：Scripts/ui-preview.sh <page> <out.png> [scrim]
#   page   root-single | root-double | root-empty | nodes | groups | subscriptions
#          | subscriptions-empty | subscriptions-loading | subscriptions-failed
#          | subscription-new | connections | settings | log | log-empty
#   scrim  legacy | light | balanced | solid（默认取代码里的默认档）
#
# 只用于视觉走查：夹具窗口不启动内核、不碰系统代理，也不读写用户配置。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGE="${1:?page}"
OUT="${2:?out.png}"
SCRIM="${3:-}"
APPEARANCE="${4:-}"
APP="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 \
  -type d -name Clash.app -path "*/Build/Products/Debug/*" | head -1)"
[[ -n "$APP" ]] || { echo "找不到 Debug 产物，请先 xcodebuild" >&2; exit 1; }

LOG="$(mktemp -t clash-preview)"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null || true
  done
  rm -f "$LOG"
}
trap cleanup EXIT

ENV_ARGS=(CLASH_PREVIEW_PAGE="$PAGE" CLASH_PREVIEW_HIDE_FOCUS=1)
if [[ -n "$SCRIM" ]]; then ENV_ARGS+=(CLASH_SCRIM_VARIANT="$SCRIM"); fi
if [[ -n "$APPEARANCE" ]]; then ENV_ARGS+=(CLASH_PREVIEW_APPEARANCE="$APPEARANCE"); fi

mkdir -p "$(dirname "$OUT")"

# 等前一次夹具退干净，避免两个窗口叠在一起
for _ in $(seq 1 40); do
  pgrep -f 'Build/Products/Debug/Clash.app/Contents/MacOS/Clash' >/dev/null || break
  pkill -9 -f 'Build/Products/Debug/Clash.app/Contents/MacOS/Clash' 2>/dev/null || true
  sleep 0.15
done
sleep 0.3

env "${ENV_ARGS[@]}" "$APP/Contents/MacOS/Clash" >"$LOG" 2>&1 &
PIDS+=("$!")

REGION=""
for _ in $(seq 1 80); do
  REGION="$(grep -m1 'CLASH_PREVIEW_REGION' "$LOG" 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$REGION" ]] && break
  sleep 0.1
done
[[ -n "$REGION" ]] || { echo "夹具没起来，日志：" >&2; cat "$LOG" >&2; exit 1; }

# 留两帧给材质与文字渲染
sleep 1.0
screencapture -x -t png -R "$REGION" "$OUT"
echo "$OUT ($PAGE${SCRIM:+, scrim=$SCRIM})"
