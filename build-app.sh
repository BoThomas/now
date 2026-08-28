#!/bin/zsh
set -euo pipefail

APP_NAME="now"
EXECUTABLE="now"
APP="outputs/${APP_NAME}.app"
ICONSET=".build/AppIcon.iconset"
# Resolve the SDK dynamically (CommandLineTools or full Xcode) instead of
# pinning one version; override with SDK_PATH=… if ever needed.
SDK_PATH="${SDK_PATH:-$(xcrun --show-sdk-path)}"
MODULE_CACHE="$(pwd)/.build/ModuleCache"
REQUIRE_IDENTITY=false

for arg in "$@"; do
  case "$arg" in
    --require-identity) REQUIRE_IDENTITY=true ;;
    *) echo "usage: ./build-app.sh [--require-identity]" >&2; exit 1 ;;
  esac
done

rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build outputs

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE"

swiftc -parse-as-library -swift-version 5 -sdk "$SDK_PATH" -target arm64-apple-macos13.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/$EXECUTABLE" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework EventKit

swiftc -sdk "$SDK_PATH" -target arm64-apple-macos13.0 make-icon.swift -o .build/make-icon
.build/make-icon "$ICONSET"
cp "$ICONSET/icon_512x512@2x.png" "$APP/Contents/Resources/AppIcon.png"

cp Info.plist "$APP/Contents/Info.plist"

# Sign with the stable self-signed "now Developer" identity when present — its
# certificate hash anchors the code signature's designated requirement, so TCC
# (Calendar permission) grants survive rebuilds and release updates. Without the
# identity, fall back to ad-hoc signing (cdhash-anchored → permission re-asked
# per build) — but only for local development builds: releases must never ship
# ad-hoc (an update signed differently silently invalidates Calendar grants).
# The key lives in the login keychain; never commit it (see AGENTS.md).
if ! codesign --force --deep --sign "now Developer" --entitlements now.entitlements "$APP"; then
  if [[ "$REQUIRE_IDENTITY" == true ]]; then
    echo "error: 'now Developer' identity not found, but stable signing is required" >&2
    echo "       (releases must not fall back to ad-hoc — see AGENTS.md → Code signing)" >&2
    exit 1
  fi
  echo "warning: 'now Developer' identity not found — signing ad-hoc (Calendar permission will be re-asked per build)"
  codesign --force --deep --sign - --entitlements now.entitlements "$APP"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "outputs/${APP_NAME}.zip"

echo "Built $APP"
