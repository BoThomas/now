#!/bin/zsh
set -euo pipefail

APP_NAME="now"
EXECUTABLE="now"
APP="outputs/${APP_NAME}.app"
ICONSET=".build/AppIcon.iconset"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
MODULE_CACHE="$(pwd)/.build/ModuleCache"

rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build outputs

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

swiftc -parse-as-library -swift-version 5 -sdk "$SDK_PATH" -target arm64-apple-macos13.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/$EXECUTABLE" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement

swiftc -sdk "$SDK_PATH" -target arm64-apple-macos13.0 make-icon.swift -o .build/make-icon
.build/make-icon "$ICONSET"
cp "$ICONSET/icon_512x512@2x.png" "$APP/Contents/Resources/AppIcon.png"

cp Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "outputs/${APP_NAME}.zip"

echo "Built $APP"
