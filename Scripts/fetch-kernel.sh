#!/usr/bin/env bash
# 预置/刷新内核与 geodata（开发 + CI；正常用户首次连接时 App 会自动下载）
#
# ADR-0012 +「补充：允许 x86_64 与内置内核变体」：
# - 二进制与 geodata 落到用户目录 ~/Library/Application Support/Clash/kernel/
# - 仓库只保留 Resources/Kernel/VERSION + SHA256-<arch>（版本与校验依据，仍由本脚本更新）
# - 双架构：darwin-arm64 / darwin-amd64 都拉，校验值分别写 SHA256-arm64 / SHA256-amd64；
#   两个架构的 mihomo 暂存到 Resources/Kernel/.stage/（gitignore），供 CLASH_BUNDLE_KERNEL=1 打包时拷进 App
#
# 用法：Scripts/fetch-kernel.sh [--dry-run] [--skip-geodata] [--version vX.Y.Z]
#
# 版本策略：取 latest（用户已确认）。可复现性由 VERSION + SHA256-<arch> 保证。
# 架构策略：arm64 + amd64（Apple Silicon / Intel 各一份，互不替代）。
set -euo pipefail

REPO="MetaCubeX/mihomo"
ARCHES=("arm64" "amd64")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Library/Application Support/Clash/kernel"
META="$ROOT/Resources/Kernel"
STAGE="$META/.stage"
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

# 本机架构 → 上游资产后缀（脚本只把本机那份装进用户目录，另一份留给打包）
case "$(uname -m)" in
  arm64) HOST_ARCH="arm64" ;;
  x86_64) HOST_ARCH="amd64" ;;
  *) echo "不支持的架构：$(uname -m)" >&2; exit 1 ;;
esac

if [[ -n "$PINNED_VERSION" ]]; then
  api="https://api.github.com/repos/$REPO/releases/tags/$PINNED_VERSION"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi
# CI 里 runner 共享出口 IP，未认证 API 很容易吃到 60 次/小时的限流（403）。
# 有 GITHUB_TOKEN 就带上，并统一给网络请求加重试。
AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
if [ "${#AUTH[@]}" -eq 0 ]; then
  json="$(curl -fsSL --retry 3 --retry-delay 2 -H 'Accept: application/vnd.github+json' "$api")"
else
  json="$(curl -fsSL --retry 3 --retry-delay 2 "${AUTH[@]}" -H 'Accept: application/vnd.github+json' "$api")"
fi

tag="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"

# 精确匹配基线资产名，排除 -go1xx / -compatible 等变体；两个架构各取一条
asset_urls=()
for arch in "${ARCHES[@]}"; do
  asset_urls+=("$(
    printf '%s' "$json" | python3 -c '
import json, sys
arch, tag = sys.argv[1], sys.argv[2]
rel = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
name = f"mihomo-darwin-{arch}-{tag}.gz"
if name not in assets:
    sys.exit(f"资产不存在: {name}")
print(assets[name])
' "$arch" "$tag"
  )")
done

echo "内核版本: $tag"
echo "本机架构: $(uname -m) → $HOST_ARCH"
for i in "${!ARCHES[@]}"; do
  echo "资产:     ${asset_urls[$i]##*/}"
done
echo "目标目录: $DEST"
echo "暂存目录: ${STAGE}（双架构，供 CLASH_BUNDLE_KERNEL=1 打包）"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run，不下载)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$DEST" "$META" "$STAGE"
printf '%s\n' "$tag" > "$META/VERSION"

for i in "${!ARCHES[@]}"; do
  arch="${ARCHES[$i]}"
  url="${asset_urls[$i]}"
  asset_name="${url##*/}"

  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$tmp/$asset_name"
  gunzip -f "$tmp/$asset_name"
  bin="$tmp/${asset_name%.gz}"

  archs="$(lipo -archs "$bin")"
  expect="$arch"
  [[ "$arch" == "amd64" ]] && expect="x86_64"
  if [[ "$archs" != "$expect" ]]; then
    echo "架构不符，期望 ${expect}，实际 ${archs}（${asset_name}）" >&2
    exit 1
  fi

  install -m 0755 "$bin" "$STAGE/mihomo-$arch"
  ( cd "$STAGE" && shasum -a 256 "mihomo-$arch" > "$META/SHA256-$arch" )
  echo "已暂存: $STAGE/mihomo-${arch}（架构 ${archs}）"

  if [[ "$arch" == "$HOST_ARCH" ]]; then
    install -m 0755 "$bin" "$DEST/mihomo"
    echo "已写入: $DEST/mihomo"
  fi
done

echo "校验值: $META/SHA256-arm64 / $META/SHA256-amd64"
echo "sha256($HOST_ARCH): $(cut -d' ' -f1 "$META/SHA256-$HOST_ARCH")"

# geodata：缺失时 TUN / GEOIP 规则起不来（内核会尝试在线下载，国内基本超时）
# 两个架构共用同一份；同时留一份到 stage，供内置内核变体打包（用户目录那份不进包）
if [[ $SKIP_GEODATA -eq 0 ]]; then
  GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
  for name in geoip.metadb geosite.dat; do
    if curl -fsSL --max-time 180 "$GEO_BASE/$name" -o "$tmp/$name"; then
      install -m 0644 "$tmp/$name" "$DEST/$name"
      install -m 0644 "$tmp/$name" "$STAGE/$name"
      echo "已写入: $DEST/${name}（并暂存一份供打包）"
    else
      echo "warning: 下载 $name 失败；首次连接时 App 会自动重试" >&2
    fi
  done
fi
echo "发布前同步：mihomo 版本、GPL-3.0 LICENSE 与应用内源码链接。"
