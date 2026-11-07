#!/bin/bash
# Builds ClearCall.app and a zip ready to download.
# Usage: scripts/build-app.sh <version> <build-number>
set -euo pipefail

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
APP="$OUT/ClearCall.app"

cd "$ROOT"
swift build -c release --arch arm64

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/ClearCall" "$APP/Contents/MacOS/ClearCall"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign (ad-hoc unless a signing identity is provided).
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements Resources/ClearCall.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/ClearCall-$VERSION.zip"
echo "Built $OUT/ClearCall-$VERSION.zip"
