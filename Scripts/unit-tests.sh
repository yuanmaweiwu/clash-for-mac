#!/usr/bin/env bash
# 纯函数单测：用 swiftc 把「不依赖 AppKit / 网络 / 真实文件」的源文件
# 与 Tests/main.swift 编成一个临时可执行文件直接跑。
#
# 为什么不建 Xcode test target：要动 pbxproj（多一个 target / 一堆文件归属），
# 而这里要覆盖的都是纯函数，`swiftc` 足够。断言用 Tests/main.swift 里的
# `expect`，输出 PASS / FAIL 行，失败计数进退出码：
#
#   bash Scripts/unit-tests.sh
#
# 唯一的外部依赖是 Yams（RuntimeConfigBuilder / SubscriptionFetcher 用它解析 YAML）：
#   - 先找 Xcode 已构建好的产物（Yams.swiftmodule + Yams.o + CYaml.o），秒级
#   - 找不到就在本地 SPM checkout 里 `swift build` 一次（十来秒）
#   - 可用 CLASH_YAMS_PRODUCTS 指定产物目录；指定后不再扫描其它位置
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clash-unit-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 被测的纯函数源文件（新增文件记得加进来）
SOURCES=(
    Tests/main.swift
    Tests/LogStoreCompileShims.swift
    # LogRedactor（与 LogStore 同一文件）
    Clash/Core/Services/LogStore.swift
    Clash/Core/Models/LogLine.swift
    Clash/Core/Models/KernelPhase.swift
    # RuntimeConfigBuilder 注入
    Clash/Core/Services/RuntimeConfigBuilder.swift
    Clash/Core/Services/KernelError.swift
    Clash/Core/Models/ProxyMode.swift
    Clash/Core/Paths/AppPaths.swift
    # SubscriptionFetcher 响应头解析
    Clash/Core/Services/SubscriptionFetcher.swift
    Clash/Core/Models/ProfileEntry.swift
    Clash/Core/Storage/ProfileStoreError.swift
    # ProxyNodeFilter 信息节点
    Clash/Core/Models/ProxyNodeFilter.swift
    # PortAllocator 端口判定
    Clash/Core/Services/PortAllocator.swift
    Clash/Core/Services/PortOccupant.swift
)

# MARK: - Yams

YAMS_INCLUDE=()
YAMS_LINK=()

use_products() {
    local products="$1"
    [ -d "$products/Yams.swiftmodule" ] || return 1
    [ -f "$products/Yams.o" ] || return 1
    [ -f "$products/CYaml.o" ] || return 1

    # .../Build/Products/Debug → .../SourcePackages/checkouts/Yams/...（CYaml 的 modulemap）
    local derived="${products%/Build/Products/*}"
    local cyaml="$derived/SourcePackages/checkouts/Yams/Sources/CYaml/include"
    [ -f "$cyaml/module.modulemap" ] || return 1

    YAMS_INCLUDE=(-I "$products" -I "$cyaml")
    YAMS_LINK=("$products/Yams.o" "$products/CYaml.o")
    echo "→ Yams 产物：$products"
}

build_yams_from_source() {
    echo "→ 未找到已编译的 Yams，本地构建一次（首次约 10s）"
    local derived="$WORK/derived"
    xcodebuild -project Clash.xcodeproj -scheme Clash \
        -resolvePackageDependencies -derivedDataPath "$derived" > "$WORK/resolve.log" 2>&1 || {
        echo "取 SPM 依赖失败，见 $WORK/resolve.log" >&2
        exit 1
    }
    local checkout="$derived/SourcePackages/checkouts/Yams"
    swift build -c release --package-path "$checkout" > "$WORK/yams-build.log" 2>&1 || {
        echo "构建 Yams 失败，见 $WORK/yams-build.log" >&2
        exit 1
    }
    local bin
    bin="$(swift build -c release --package-path "$checkout" --show-bin-path)"

    # shellcheck disable=SC2207
    local objects=($(find "$bin/Yams.build" "$bin/CYaml.build" -name '*.o'))
    YAMS_INCLUDE=(-I "$bin/Modules" -I "$checkout/Sources/CYaml/include")
    YAMS_LINK=("${objects[@]}")
    echo "→ Yams 产物：$bin"
}

if [ -n "${CLASH_YAMS_PRODUCTS:-}" ]; then
    use_products "$CLASH_YAMS_PRODUCTS" || {
        echo "CLASH_YAMS_PRODUCTS 下没有可用的 Yams 产物：$CLASH_YAMS_PRODUCTS" >&2
        exit 1
    }
else
    for candidate in \
        /tmp/dd-fix3/Build/Products/Debug \
        "$HOME"/Library/Developer/Xcode/DerivedData/Clash-*/Build/Products/Debug; do
        [ -d "$candidate" ] || continue
        use_products "$candidate" && break
    done
    [ ${#YAMS_LINK[@]} -gt 0 ] || build_yams_from_source
fi

# MARK: - 编译并运行

BINARY="$WORK/unit-tests"
echo "→ 编译 ${#SOURCES[@]} 个源文件"
swiftc \
    -swift-version 6 \
    -DDEBUG \
    "${YAMS_INCLUDE[@]}" \
    "${SOURCES[@]}" \
    "${YAMS_LINK[@]}" \
    -o "$BINARY"

echo "→ 运行"
"$BINARY"
