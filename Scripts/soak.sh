#!/usr/bin/env bash
# 真实环境长稳测试：按固定间隔采样 CPU / 内存 / 内核可用性，输出 CSV 与汇总。
#
# 用法：Scripts/soak.sh <分钟> [标签]
#   例：Scripts/soak.sh 30 baseline
#
# 采样项（每 30s）：
#   app / kernel / helper 的 RSS 与 CPU、系统代理状态、内核 /version 是否可达、内核 PID
# 判定（结束打印）：
#   RSS 均值/峰值、内存增长率（MB/小时，线性拟合）、平均 CPU、内核重启次数、可达率
#
# 只读：不启停内核、不改系统设置。需要 App 已在运行。
set -euo pipefail

MINUTES="${1:?用法: soak.sh <分钟> [标签]}"
LABEL="${2:-run}"
INTERVAL=30
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/soak"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$OUT_DIR/${STAMP}-${LABEL}.csv"
LOG="$OUT_DIR/${STAMP}-${LABEL}.log"

app_pid() { pgrep -f '/Applications/Clash.app/Contents/MacOS/Clash' | head -1; }
kernel_pid() { pgrep -f 'Application Support/Clash/kernel/mihomo' | head -1; }
helper_pid() { pgrep -f 'PrivilegedHelperTools/com.clash.helper' | head -1; }

rss_of() { [[ -n "${1:-}" ]] && ps -o rss= -p "$1" 2>/dev/null | tr -d ' ' || echo 0; }
cpu_of() { [[ -n "${1:-}" ]] && ps -o pcpu= -p "$1" 2>/dev/null | tr -d ' ' || echo 0; }

runtime_field() { # $1 = key
  local f="$HOME/Library/Application Support/Clash/runtime/runtime.yaml"
  [[ -f "$f" ]] || return 1
  case "$1" in
    port)   grep external-controller "$f" | sed -E 's/.*127.0.0.1:([0-9]+).*/\1/' ;;
    secret) grep '^secret:' "$f" | sed -E 's/secret: *"?([^"]*)"?/\1/' ;;
  esac
}

kernel_probe() {
  local port secret code
  port="$(runtime_field port || true)"
  secret="$(runtime_field secret || true)"
  [[ -z "$port" ]] && { echo "no-port"; return; }
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
    -H "Authorization: Bearer $secret" "http://127.0.0.1:$port/version" 2>/dev/null || echo 000)"
  echo "$code"
}

proxy_state() {
  networksetup -getwebproxy "Wi-Fi" 2>/dev/null | awk -F': ' '/Enabled/{print $2}' | head -1
}

echo "ts,app_rss_kb,kernel_rss_kb,helper_rss_kb,app_cpu,kernel_cpu,helper_cpu,proxy,kernel_http,kernel_pid" > "$CSV"
echo "== soak ${MINUTES}min label=${LABEL} ==" | tee "$LOG"
echo "csv: $CSV" | tee -a "$LOG"

TOTAL=$((MINUTES * 60 / INTERVAL))
restarts=0
last_kernel_pid=""
probe_ok=0
probe_all=0

for i in $(seq 1 "$TOTAL"); do
  ap="$(app_pid || true)"; kp="$(kernel_pid || true)"; hp="$(helper_pid || true)"
  if [[ -n "$kp" && -n "$last_kernel_pid" && "$kp" != "$last_kernel_pid" ]]; then
    restarts=$((restarts + 1))
    echo "! 内核 PID 变化 $last_kernel_pid -> $kp (第 $i 次采样)" | tee -a "$LOG"
  fi
  [[ -n "$kp" ]] && last_kernel_pid="$kp"

  http="$(kernel_probe)"
  probe_all=$((probe_all + 1))
  [[ "$http" == "200" ]] && probe_ok=$((probe_ok + 1))
  [[ "$http" != "200" && "$http" != "no-port" ]] && echo "! 内核不可达 http=$http (第 $i 次采样)" | tee -a "$LOG"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date +%s)" "$(rss_of "$ap")" "$(rss_of "$kp")" "$(rss_of "$hp")" \
    "$(cpu_of "$ap")" "$(cpu_of "$kp")" "$(cpu_of "$hp")" \
    "$(proxy_state || echo ?)" "$http" "${kp:-0}" >> "$CSV"

  [[ -z "$ap" ]] && { echo "! App 进程消失（第 $i 次采样）" | tee -a "$LOG"; break; }
  sleep "$INTERVAL"
done

python3 - "$CSV" "$LOG" "$restarts" "$probe_ok" "$probe_all" <<'PY'
import csv, sys, statistics

csv_path, log_path, restarts, ok, total = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
rows = list(csv.DictReader(open(csv_path)))
if not rows:
    print("没有采样数据"); raise SystemExit

def col(name):
    return [float(r[name]) for r in rows if r[name] not in ("", None)]

def summary(name, scale=1024):
    vals = col(name)
    if not vals: return f"{name}: 无数据"
    return (f"{name}: avg={statistics.mean(vals)/scale:.1f}MB "
            f"peak={max(vals)/scale:.1f}MB min={min(vals)/scale:.1f}MB")

def slope_mb_per_hour(name):
    xs = list(range(len(rows)))
    ys = col(name)
    if len(ys) < 3: return 0.0
    n = len(ys); mx = sum(xs)/n; my = sum(ys)/n
    denom = sum((x-mx)**2 for x in xs) or 1
    k = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / denom
    # 每采样 30s → 每小时 120 次采样
    return k * 120 / 1024

lines = []
lines.append("==== 汇总 ====")
lines.append(f"采样次数: {len(rows)}  时长: {len(rows)*30/60:.0f} 分钟")
lines.append(summary("app_rss_kb"))
lines.append(summary("kernel_rss_kb"))
lines.append(summary("helper_rss_kb"))
lines.append(summary("app_cpu", scale=1))
lines.append(summary("kernel_cpu", scale=1))
lines.append(f"内存增长: app={slope_mb_per_hour('app_rss_kb'):+.2f} MB/h, kernel={slope_mb_per_hour('kernel_rss_kb'):+.2f} MB/h")
lines.append(f"内核可达: {ok}/{total} ({ok/total*100:.1f}%)  内核重启: {restarts}")
out = "\n".join(lines)
print(out)
open(log_path, "a").write("\n" + out + "\n")
PY

echo "原始数据: $CSV"
