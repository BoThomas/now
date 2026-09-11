#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${NOW_TEST_CONFIGURATION:-debug}"
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || exit 2
export NOW_TEST_SUITE=selftest
./scripts/swiftpm.sh build --scratch-path .build/tests/selftest -c "$CONFIGURATION" --product now-harness
BIN_DIR=$(./scripts/swiftpm.sh build --scratch-path .build/tests/selftest -c "$CONFIGURATION" --show-bin-path)
exec "$BIN_DIR/now-harness"
