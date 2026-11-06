#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER_BIN="${FLUTTER_BIN:-/Users/hahadong/development/flutter/bin/flutter}"
if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter SDK 尚未就绪，请安装 Flutter 或设置 FLUTTER_BIN。"
  exit 1
fi
device_id="00008120-00026DE23E84201E"
if [[ $# -gt 0 && "$1" != --* ]]; then
  device_id="$1"
  shift
fi
build_mode="${IOS_BUILD_MODE:-release}"
case "$build_mode" in
  release|debug|profile) ;;
  *) echo "IOS_BUILD_MODE 只能为 release、debug 或 profile。"; exit 1 ;;
esac
exec "$FLUTTER_BIN" run "--$build_mode" -d "$device_id" "$@"
