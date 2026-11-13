#!/usr/bin/env bash
# 拉取上游 mihomo 最新 release 的 darwin/arm64 二进制，落到 Resources/Kernel/
# 同时拉 geodata（geoip.metadb / geosite.dat）：TUN 与 GEOIP 规则的硬依赖，
# helper 运行目录里没有它，内核启动时会去 GitHub 下载（国内常超时 90s）。
# 用法：Scripts/fetch-kernel.sh [--dry-run] [--skip-geodata] [--version vX.Y.Z]
#
# 版本策略：取 latest（用户已确认）。可复现性由 Resources/Kernel/VERSION + SHA256 保证。
# 架构策略：仅 arm64（Apple Silicon），不支持 x86_64（用户已确认）。
set -euo pipefail

REPO="MetaCubeX/mihomo"
ARCH="arm64"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Resources/Kernel"
DRY_RUN=0
SKIP_GEODATA=0
PINNED_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --skip-geodata) SKIP_GEODATA=1; shift ;;
    --version) PINNED_VERSION="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "$PINNED_VERSION" ]]; then
  api="https://api.github.com/repos/$REPO/releases/tags/$PINNED_VERSION"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi
json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api")"

tag="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"

# 精确匹配基线资产名，排除 -go1xx / -compatible 等变体
asset_url="$(
  printf '%s' "$json" | python3 -c '
import json, sys
arch, tag = sys.argv[1], sys.argv[2]
rel = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
name = f"mihomo-darwin-{arch}-{tag}.gz"
if name not in assets:
    sys.exit(f"资产不存在: {name}")
print(assets[name])
' "$ARCH" "$tag"
)"

asset_name="${asset_url##*/}"
echo "内核版本: $tag"
echo "资产:     $asset_name"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run，不下载)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$asset_url" -o "$tmp/$asset_name"
gunzip -f "$tmp/$asset_name"
bin="$tmp/${asset_name%.gz}"

mkdir -p "$DEST"
install -m 0755 "$bin" "$DEST/mihomo"
printf '%s\n' "$tag" > "$DEST/VERSION"
( cd "$DEST" && shasum -a 256 mihomo > SHA256 )

archs="$(lipo -archs "$DEST/mihomo")"
if [[ "$archs" != "arm64" ]]; then
  echo "架构不符，期望 arm64，实际 $archs" >&2
  exit 1
fi

echo "架构: $archs"
echo "sha256: $(cut -d' ' -f1 "$DEST/SHA256")"
echo "已写入: $DEST/mihomo（二进制不入库，仅 VERSION / SHA256 入库）"

# geodata：缺失时 TUN 起不来（内核会尝试在线下载 MMDB，国内基本超时）
if [[ $SKIP_GEODATA -eq 0 ]]; then
  GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
  for name in geoip.metadb geosite.dat; do
    if curl -fsSL --max-time 180 "$GEO_BASE/$name" -o "$DEST/$name"; then
      echo "已写入: $DEST/$name"
    else
      echo "warning: 下载 $name 失败；TUN / GEOIP 规则需要它，可把已有文件手工放到 $DEST/" >&2
    fi
  done
fi
echo "发布前同步：mihomo 版本、GPL-3.0 LICENSE 与源码地址。"
