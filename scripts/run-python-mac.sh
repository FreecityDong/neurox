#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../KSEEG102_Python_Mac"
# Local Homebrew Python needs its compatible expat on this Mac.
if [[ -d /opt/homebrew/opt/expat/lib ]]; then
  export DYLD_LIBRARY_PATH="/opt/homebrew/opt/expat/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
if [[ -z "${PYTHON_BIN:-}" && -x /opt/homebrew/bin/python3.12 ]]; then
  export PYTHON_BIN=/opt/homebrew/bin/python3.12
fi
export PYTHONUNBUFFERED=1
exec bash start.command "$@"
