#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" ]]; then FLUTTER_BIN="$HOME/development/flutter/bin/flutter"; fi
if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "请先安装 Flutter，或配置 FLUTTER_BIN。"
  exit 1
fi
exec "$FLUTTER_BIN" run -d web-server --web-port "${PORT:-7357}" --web-hostname 127.0.0.1
