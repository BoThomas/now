#!/bin/zsh
# Shared SwiftPM toolchain entry point; all caches stay local.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
COMMAND="$1"
shift
# Resolve before exec so SDK lookup failure cannot launch a wrong-host build.
SDK_PATH="${SDK_PATH:-$(xcrun --show-sdk-path)}"
exec swift "$COMMAND" --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" \
  --arch arm64 -Xswiftc -sdk -Xswiftc "$SDK_PATH" "$@"
