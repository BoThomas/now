#!/bin/zsh
# Isolated interactive updater tour; --smoke drives the real GUI install/relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/update-ui-demo.py "$@"
