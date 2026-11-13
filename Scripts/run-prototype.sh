#!/usr/bin/env bash
# 启动 Clash 面板原型：SPM 可执行包，零第三方依赖，不生成 .xcodeproj。
# 用法：./Scripts/run-prototype.sh
# 额外参数会透传，例如 --snapshot <目录> / --measure。
set -euo pipefail

cd "$(dirname "$0")/../Prototype"
exec swift run ClashPrototype "$@"
