#!/bin/sh
# 构建期：把 Kernel 资源铺到 Contents/Resources/Kernel/
#
# ADR-0012 +「补充：允许 x86_64 与内置内核变体」：
# - 默认只放 VERSION + SHA256-arm64 + SHA256-amd64（内核运行时下载）
# - CLASH_BUNDLE_KERNEL=1 时额外把当前架构的 mihomo 与 geodata 打进包（内置内核变体，
#   体积 +56MB 二进制 / 压缩后约 +25MB），运行期直接从包里拷出、不联网
set -eu

SRC_DIR="$SRCROOT/Resources/Kernel"
DEST_DIR="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/Kernel"

# 先清空：不带 CLASH_BUNDLE_KERNEL 的构建里绝不能残留上一次的内核
# （否则「下载包」会因为增量构建偷偷变成内置包）
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

for name in VERSION SHA256-arm64 SHA256-amd64; do
  if [ ! -f "$SRC_DIR/$name" ]; then
    echo "error: 缺少 $SRC_DIR/${name}（先跑 Scripts/fetch-kernel.sh）"
    exit 1
  fi
  ditto "$SRC_DIR/$name" "$DEST_DIR/$name"
done

# 打进包的架构：单架构构建取 ${ARCHS}；通用构建按 arm64 优先
# （四种发布包都是单架构构建，通用构建只用于本地调试）
BUNDLE_ARCH=""
for candidate in ${ARCHS:-}; do
  case "$candidate" in
    arm64|amd64|x86_64) BUNDLE_ARCH="$candidate"; break ;;
  esac
done
[ -n "$BUNDLE_ARCH" ] || BUNDLE_ARCH="$(uname -m)"
case "$BUNDLE_ARCH" in
  x86_64|amd64) KERNEL_ARCH="amd64" ;;
  *) KERNEL_ARCH="arm64" ;;
esac

if [ "${CLASH_BUNDLE_KERNEL:-0}" = "1" ]; then
  if [ ! -f "$SRC_DIR/.stage/mihomo-$KERNEL_ARCH" ]; then
    echo "error: CLASH_BUNDLE_KERNEL=1 但缺少 $SRC_DIR/.stage/mihomo-${KERNEL_ARCH}（先跑 Scripts/fetch-kernel.sh）"
    exit 1
  fi
  ditto "$SRC_DIR/.stage/mihomo-$KERNEL_ARCH" "$DEST_DIR/mihomo"
  chmod 0755 "$DEST_DIR/mihomo"
  # geodata 两个架构共用；随包带一份，内置变体首启连它也不下载
  for name in geoip.metadb geosite.dat; do
    if [ -f "$SRC_DIR/.stage/$name" ]; then
      ditto "$SRC_DIR/.stage/$name" "$DEST_DIR/$name"
    else
      echo "warning: 缺少 $SRC_DIR/.stage/${name}（内置变体首次运行会联网补）"
    fi
  done
  echo "Bundled kernel: $DEST_DIR/mihomo（arch=${KERNEL_ARCH}）"
else
  echo "Copied kernel metadata only: ${DEST_DIR}（内核运行时下载）"
fi
