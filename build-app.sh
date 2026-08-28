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
SIGNING_IDENTITY_SHA1="${NOW_SIGNING_IDENTITY_SHA1:-A505B08900C56A28709479297A049525A2A187C6}"

[[ "$SIGNING_IDENTITY_SHA1" =~ '^[[:xdigit:]]{40}$' ]] || {
  echo "error: NOW_SIGNING_IDENTITY_SHA1 must be a 40-digit SHA-1 fingerprint" >&2
  exit 1
}
SIGNING_IDENTITY_SHA1="${(U)SIGNING_IDENTITY_SHA1}"

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

# Sign with the exact stable self-signed identity when present — its
# certificate hash anchors the code signature's designated requirement, so TCC
# (Calendar permission) grants survive rebuilds and release updates. Without the
# identity, fall back to ad-hoc signing (cdhash-anchored → permission re-asked
# per build) — but only for local development builds: releases must never ship
# ad-hoc (an update signed differently silently invalidates Calendar grants).
# The key lives in the login keychain; never commit it (see AGENTS.md).
STABLE_SIGNATURE=false
AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning)
if [[ "$AVAILABLE_IDENTITIES" == *"$SIGNING_IDENTITY_SHA1"* ]]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY_SHA1" --entitlements now.entitlements "$APP"
  STABLE_SIGNATURE=true
else
  if [[ "$REQUIRE_IDENTITY" == true ]]; then
    echo "error: signing identity $SIGNING_IDENTITY_SHA1 not found, but stable signing is required" >&2
    echo "       (releases must not fall back to ad-hoc — see AGENTS.md → Code signing)" >&2
    exit 1
  fi
  echo "warning: signing identity $SIGNING_IDENTITY_SHA1 not found — signing ad-hoc (Calendar permission will be re-asked per build)"
  codesign --force --deep --sign - --entitlements now.entitlements "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
DESIGNATED_REQUIREMENT=$(codesign -d -r- "$APP" 2>&1) || {
  echo "error: could not read the app's designated requirement" >&2
  exit 1
}
[[ "$DESIGNATED_REQUIREMENT" == *"designated =>"* ]] || {
  echo "error: signed app has no designated requirement" >&2
  exit 1
}

if [[ "$STABLE_SIGNATURE" == true ]]; then
  CERT_PREFIX=".build/signature-cert"
  codesign -d --extract-certificates="$CERT_PREFIX" "$APP" >/dev/null 2>&1
  ACTUAL_SHA1=$(openssl x509 -inform DER -in "${CERT_PREFIX}0" -noout -fingerprint -sha1 |
    sed 's/^.*=//; s/://g' | tr '[:lower:]' '[:upper:]')
  rm -f "${CERT_PREFIX}"*
  [[ "$ACTUAL_SHA1" == "$SIGNING_IDENTITY_SHA1" ]] || {
    echo "error: app was signed by unexpected identity $ACTUAL_SHA1" >&2
    exit 1
  }
  EXPECTED_ROOT="certificate root = H\"${(L)SIGNING_IDENTITY_SHA1}\""
  [[ "$DESIGNATED_REQUIREMENT" == *"$EXPECTED_ROOT"* ]] || {
    echo "error: designated requirement is not anchored to $SIGNING_IDENTITY_SHA1" >&2
    exit 1
  }
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "outputs/${APP_NAME}.zip"

echo "Built $APP"
