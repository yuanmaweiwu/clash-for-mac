#!/usr/bin/env bash
# 系统代理自检：构建 → 逐模式跑 DEBUG harness → networksetup 原始输出前后 diff。
#
# 用法：Scripts/check-system-proxy.sh [--no-build]
#
# 覆盖：开启/还原逐字段一致、退出路径还原、崩溃兜底还原、失败回滚、快照写不进去时整体放弃。
# 结束时保证：系统代理已关闭、快照已删除，且所有服务的代理项与测试前一致。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Clash.app"
NETWORK="/usr/sbin/networksetup"
SNAPSHOT="${HOME}/Library/Application Support/Clash/systemproxy-snapshot.json"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clash-proxy-check.XXXXXX")"
FAILED=0

echo "==> 工作目录：$WORK"

if [[ -e "$SNAPSHOT" ]]; then
  echo "FAIL 已存在代理快照，说明当前有未还原的代理，先手动处理：$SNAPSHOT" >&2
  exit 1
fi

if [[ "${1:-}" != "--no-build" ]]; then
  echo "==> 构建"
  xcodebuild -project Clash.xcodeproj -scheme Clash -configuration Debug build \
    | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | tail -5
fi

APP="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -type d -name "$APP_NAME" -path "*/Build/Products/Debug/*" | head -1)"
if [[ -z "$APP" ]]; then
  echo "找不到构建产物，先跑一次 xcodebuild" >&2
  exit 1
fi
BIN="$APP/Contents/MacOS/Clash"
echo "==> 产物：$BIN"

dump_proxy_state() {
  "$NETWORK" -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r service; do
    echo "### ${service}"
    echo "--- web"
    "$NETWORK" -getwebproxy "$service"
    echo "--- secure"
    "$NETWORK" -getsecurewebproxy "$service"
    echo "--- socks"
    "$NETWORK" -getsocksfirewallproxy "$service"
    echo "--- auto"
    "$NETWORK" -getautoproxyurl "$service"
    echo "--- bypass"
    "$NETWORK" -getproxybypassdomains "$service"
  done
}

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILED=1; }

# 跑一个 harness 模式；$1 = 模式名
run_mode() {
  local mode="$1"
  local log="$WORK/${mode}.log"
  set +e
  CLASH_PROXY_HARNESS="$mode" "$BIN" > "$log" 2>&1
  local status=$?
  set -e
  if grep -q "HARNESS DONE failures=0" "$log"; then
    pass "harness $mode"
  else
    fail "harness $mode（exit=$status）"
    sed -n '1,80p' "$log"
  fi
}

# 模式后：快照必须不存在 + 原始设置与 before 逐字节一致
verify_clean() {
  local label="$1"
  local after="$WORK/after-${label}.txt"
  dump_proxy_state > "$after"

  if [[ -e "$SNAPSHOT" ]]; then
    fail "${label}: 快照未删除"
  else
    pass "${label}: 快照已删除"
  fi

  if diff -u "$WORK/before.txt" "$after" > "$WORK/diff-${label}.txt"; then
    pass "${label}: 代理项与测试前逐字段一致"
  else
    fail "${label}: 代理项与测试前不一致"
    cat "$WORK/diff-${label}.txt"
  fi
}

echo "==> 记录测试前状态"
dump_proxy_state > "$WORK/before.txt"

echo "==> 模式 roundtrip（enable → 读回校验 → disable）"
run_mode roundtrip
verify_clean roundtrip

echo "==> 模式 hold（开启后留 6s 窗口，外部读 networksetup 取证）"
set +e
CLASH_PROXY_HARNESS=hold "$BIN" > "$WORK/hold.log" 2>&1 &
HOLD_PID=$!
set -e

for _ in $(seq 1 600); do
  [[ -e "$SNAPSHOT" ]] && break
  sleep 0.1
done
for _ in $(seq 1 200); do
  if "$NETWORK" -getwebproxy "Wi-Fi" | grep -q "Enabled: Yes"; then
    break
  fi
  sleep 0.1
done
sleep 0.3
dump_proxy_state > "$WORK/during-hold.txt"

HOLD_STATUS=0
wait "$HOLD_PID" || HOLD_STATUS=$?
if grep -q "HARNESS DONE failures=0" "$WORK/hold.log"; then
  pass "harness hold"
else
  fail "harness hold（exit=$HOLD_STATUS）"
  sed -n '1,80p' "$WORK/hold.log"
fi

echo "--- 代理开启时的 Wi-Fi 原始读回 ---"
sed -n '/^### Wi-Fi$/,/^### /p' "$WORK/during-hold.txt" | head -16
if grep -A4 '^### Wi-Fi$' "$WORK/during-hold.txt" | grep -q "127.0.0.1" \
  && grep -A4 '^### Wi-Fi$' "$WORK/during-hold.txt" | grep -q "Port: 7890" \
  && grep -A4 '^### Wi-Fi$' "$WORK/during-hold.txt" | grep -q "Enabled: Yes"; then
  pass "hold: Wi-Fi web = Enabled Yes / 127.0.0.1 / 7890"
else
  fail "hold: Wi-Fi web 读回不符合预期"
fi
verify_clean hold

echo "==> 模式 stale（模拟崩溃后重启 → restoreIfNeeded 兜底）"
run_mode stale
verify_clean stale

echo "==> 模式 terminate（App 退出路径：同步还原）"
run_mode terminate
verify_clean terminate

echo "==> 模式 panel（连接磁贴 = 系统代理总开关：起内核 + 接管 / 还原 + 停内核）"
run_mode panel
verify_clean panel

echo "==> 模式 rollback（读回校验注入失败 → 必须回滚）"
run_mode rollback
verify_clean rollback

echo "==> 模式 readonly（快照目录不可写 → 必须整体放弃）"
RO_DIR="$WORK/readonly"
mkdir -p "$RO_DIR"
chmod 500 "$RO_DIR"
set +e
CLASH_PROXY_HARNESS=readonly \
CLASH_PROXY_SNAPSHOT_PATH="$RO_DIR/snapshot.json" \
  "$BIN" > "$WORK/readonly.log" 2>&1
RO_STATUS=$?
set -e
chmod 700 "$RO_DIR"
if grep -q "HARNESS DONE failures=0" "$WORK/readonly.log"; then
  pass "harness readonly"
else
  fail "harness readonly（exit=$RO_STATUS）"
  sed -n '1,80p' "$WORK/readonly.log"
fi
verify_clean readonly

echo "==> 结论"
if [[ "$FAILED" -ne 0 ]]; then
  echo "FAIL 系统代理自检未通过；工作目录：$WORK"
  exit 1
fi
echo "PASS 系统代理自检全部通过（测试前后逐字段一致，快照已删除）"
echo "工作目录：$WORK"
