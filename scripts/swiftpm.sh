#!/bin/zsh
# Shared SwiftPM toolchain entry point; all caches stay local.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/macos-toolchain.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
COMMAND="$1"
shift
# Explicit transition backend: Swift 6.4's new default emitted sdk13.0 for a
# selected SDK27, even in a minimal package. Do not silently change backends;
# revisit this deprecated option after the upstream path passes our SDK gate.
exec "$NOW_SWIFT" "$COMMAND" --build-system "$NOW_SWIFTPM_BACKEND" --sdk "$SDK_PATH" \
  --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" --arch arm64 "$@"
