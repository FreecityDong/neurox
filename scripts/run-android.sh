#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" ]]; then FLUTTER_BIN="$HOME/development/flutter/bin/flutter"; fi
ADB_BIN="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
if [[ ! -x "$FLUTTER_BIN" || ! -x "$ADB_BIN" ]]; then
  echo "请先安装 Flutter 和 Android SDK，并配置 FLUTTER_BIN / ANDROID_HOME。"
  exit 1
fi
DEVICE_ID="${1:-$("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
if [[ -z "$DEVICE_ID" ]]; then
  echo "未检测到已授权的 Android 设备。请连接手机、开启 USB 调试并允许电脑调试。"
  "$ADB_BIN" devices -l
  exit 1
fi
exec "$FLUTTER_BIN" run -d "$DEVICE_ID"
