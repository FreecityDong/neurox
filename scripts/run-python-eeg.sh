#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHON_BIN="eegTest/.venv-macos/bin/python"
# This macOS version's system expat lacks symbols required by Homebrew Python.
if [[ -d /opt/homebrew/opt/expat/lib ]]; then
  export DYLD_LIBRARY_PATH="/opt/homebrew/opt/expat/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "请先用支持 Tkinter 的 Python 3.12 建立 eegTest/.venv-macos 并安装 eegTest/requirements.txt。"
  exit 1
fi
if [[ "${1:-}" == "--check" ]]; then
  shift
  exec "$PYTHON_BIN" -u scripts/check-python-eeg.py "$@"
fi
if [[ "${1:-}" == "--web" ]]; then
  shift
  exec "$PYTHON_BIN" -u scripts/eeg_browser_bridge.py "$@"
fi
exec "$PYTHON_BIN" eegTest/eeg_viewer.py "$@"
