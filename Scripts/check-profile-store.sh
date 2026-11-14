#!/usr/bin/env bash
# 订阅库自检（五条链路）：构建 → 本地订阅服务器 → DEBUG harness → 断言 → 入库文件再跑 `mihomo -t`。
#
# 用法：Scripts/check-profile-store.sh [--no-build]
# 产物与输出留在 ${WORK}（打印在末尾）；服务器退出即关。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="Clash"
APP_NAME="Clash.app"
KERNEL="$ROOT/Resources/Kernel/mihomo"
KERNEL_DIR="${HOME}/Library/Application Support/Clash/kernel"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clash-profile-check.XXXXXX")"
PORT_FILE="$WORK/port"
SERVER_LOG="$WORK/server.log"

cat > "$WORK/server.py" <<'PY'
import http.server
import json
import socketserver
import sys


SUBSCRIPTION_YAML = """mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
dns:
  enable: true
  listen: 0.0.0.0:1053
proxies:
  - name: 机场节点 A
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-128-gcm
    password: test-password
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 机场节点 A
rules:
  - MATCH,节点选择
""".encode("utf-8")


class Server(http.server.HTTPServer):
    """跳过 server_bind 里的 reverse DNS（getfqdn 在本机会卡住几十秒）"""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Handler(http.server.BaseHTTPRequestHandler):
    flaky_hits = 0

    def log_message(self, *args):
        pass

    def do_GET(self):
        user_agent = self.headers.get("User-Agent", "")
        # /sub 只认预设 UA：验证「默认 UA 被 422 → 自动换 UA 重试一次」
        if self.path.startswith("/sub"):
            if not user_agent.lower().startswith("clash-verge"):
                return self.send_json(422, {"detail": "此客户端格式不支持当前套餐节点，请选择其他格式"})
            return self.send_subscription()

        # /flaky：第一次 200，之后一律 422（验证失败更新保留旧配置）
        if self.path.startswith("/flaky"):
            Handler.flaky_hits += 1
            if Handler.flaky_hits > 1:
                return self.send_json(422, {"detail": "flaky"})
            return self.send_subscription()

        self.send_json(404, {"detail": "not found"})

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_subscription(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("subscription-userinfo", "upload=1024; download=2048; total=107374182400")
        self.send_header("Profile-Update-Interval", "6")
        self.send_header("Profile-Web-Page-Url", "https://example.com/panel")
        self.send_header(
            "Content-Disposition",
            "attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95%E6%9C%BA%E5%9C%BA.yaml",
        )
        self.send_header("Content-Length", str(len(SUBSCRIPTION_YAML)))
        self.end_headers()
        self.wfile.write(SUBSCRIPTION_YAML)


def main():
    server = Server(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    server.serve_forever()


main()
PY

python3 "$WORK/server.py" "$PORT_FILE" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done
if [[ ! -s "$PORT_FILE" ]]; then
  echo "订阅服务器未启动，日志：$SERVER_LOG" >&2
  cat "$SERVER_LOG" >&2 || true
  exit 1
fi
PORT="$(cat "$PORT_FILE")"
echo "==> 本地订阅服务器 127.0.0.1:$PORT"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "==> 构建"
  xcodebuild -project Clash.xcodeproj -scheme "$SCHEME" -configuration Debug build \
    | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | tail -5
fi

APP="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -type d -name "$APP_NAME" -path "*/Build/Products/Debug/*" | head -1)"
if [[ -z "$APP" ]]; then
  echo "找不到构建产物，先跑一次 xcodebuild" >&2
  exit 1
fi
BIN="$APP/Contents/MacOS/Clash"
echo "==> 产物：$BIN"

DATA="$WORK/data"
mkdir -p "$DATA"
OUTPUT="$WORK/harness.log"

set +e
CLASH_PROFILE_HARNESS="$DATA" \
CLASH_HARNESS_URL="http://127.0.0.1:$PORT/sub" \
CLASH_HARNESS_FAIL_URL="http://127.0.0.1:$PORT/flaky" \
CLASH_HARNESS_DEAD_URL="http://127.0.0.1:1/sub" \
  "$BIN" 2>&1 | tee "$OUTPUT"
STATUS="${PIPESTATUS[0]}"
set -e

echo "==> 入库文件再跑 mihomo -t"
MIHOMO_FAILED=0
if [[ -d "$WORK/data/artifacts" ]]; then
  for file in "$WORK"/data/artifacts/*.yaml; do
    [[ -f "$file" ]] || continue
    if "$KERNEL" -t -d "$KERNEL_DIR" -f "$file" > /dev/null 2>&1; then
      echo "PASS mihomo -t $(basename "$file")"
    else
      echo "FAIL mihomo -t $(basename "$file")"
      MIHOMO_FAILED=1
    fi
  done
else
  echo "FAIL 没有 artifacts 目录，无法复检" 
  MIHOMO_FAILED=1
fi

echo "==> 结果"
if [[ "$STATUS" -ne 0 ]] || ! grep -q "HARNESS DONE failures=0" "$OUTPUT"; then
  echo "FAIL 自检未全部通过（exit=${STATUS}）"
  [[ "$MIHOMO_FAILED" -eq 0 ]] || echo "FAIL mihomo -t 复检失败"
  echo "工作目录：$WORK"
  exit 1
fi
if [[ "$MIHOMO_FAILED" -ne 0 ]]; then
  echo "FAIL mihomo -t 复检失败"
  echo "工作目录：$WORK"
  exit 1
fi

echo "PASS 五条链路全部通过"
echo "工作目录：$WORK"
