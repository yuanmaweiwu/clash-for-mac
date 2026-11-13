#!/usr/bin/env bash
# 拉取上游 mihomo 最新 release 的 darwin 二进制，合成通用二进制落到 Resources/Kernel/
# 用法：Scripts/fetch-kernel.sh [--dry-run]
#
# 版本策略：取 latest（用户已确认）。可复现性由 Resources/Kernel/VERSION + SHA256 保证。
set -euo pipefail

REPO="MetaCubeX/mihomo"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Resources/Kernel"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

api="https://api.github.com/repos/$REPO/releases/latest"
json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api")"

tag="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"

# 选资产：优先精确名（基线 amd64 + arm64，排除 -go1xx / -compatible / -v2 / -v3 变体）
pick() {
  python3 -c '
import json, sys
arch, tag = sys.argv[1], sys.argv[2]
rel = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
name = f"mihomo-darwin-{arch}-{tag}.gz"
print(assets.get(name, ""))
' "$1" "$tag"
}

arm_url="$(printf '%s' "$json" | pick arm64)"
intel_url="$(printf '%s' "$json" | pick amd64)"

[[ -n "$arm_url" ]] || { echo "找不到 darwin-arm64 资产" >&2; exit 1; }

echo "内核版本: $tag"
echo "arm64:    ${arm_url##*/}"
[[ -n "$intel_url" ]] && echo "amd64:    ${intel_url##*/}" || echo "amd64:    缺失（将只出 arm64）"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run，不下载)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() { # url -> path
  local url="$1" name
  name="${url##*/}"
  curl -fsSL "$url" -o "$tmp/$name"
  gunzip -f "$tmp/$name"
  echo "$tmp/${name%.gz}"
}

arm_bin="$(fetch "$arm_url")"
bins=("$arm_bin")
if [[ -n "$intel_url" ]]; then
  bins+=("$(fetch "$intel_url")")
fi

mkdir -p "$DEST"
if [[ ${#bins[@]} -eq 2 ]]; then
  lipo -create "${bins[@]}" -output "$DEST/mihomo"
else
  cp -f "${bins[0]}" "$DEST/mihomo"
fi
chmod +x "$DEST/mihomo"

printf '%s\n' "$tag" > "$DEST/VERSION"
( cd "$DEST" && shasum -a 256 mihomo > SHA256 )

echo "架构: $(lipo -archs "$DEST/mihomo")"
echo "sha256: $(cut -d' ' -f1 "$DEST/SHA256")"
echo "已写入: $DEST/mihomo（二进制不入库，仅 VERSION / SHA256 入库）"
echo "发布前同步：mihomo 版本、GPL-3.0 LICENSE 与源码地址。"
