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

# 1. WebRTC audio processing (echo cancellation), as static libraries.
"$ROOT/scripts/build-webrtc.sh"
export PKG_CONFIG_PATH="$ROOT/vendor/webrtc/lib/pkgconfig"
CFLAGS="$(pkg-config --cflags webrtc-audio-processing-2)"
LIBS="$(pkg-config --static --libs webrtc-audio-processing-2)"
echo "WebRTC cflags: $CFLAGS"
echo "WebRTC libs:   $LIBS"

SWIFT_FLAGS=(-c release --arch arm64)
for f in $CFLAGS; do SWIFT_FLAGS+=(-Xcxx "$f"); done
for f in $LIBS; do SWIFT_FLAGS+=(-Xlinker "$f"); done

# 2. The app.
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/ClearCall"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClearCall"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The app must not depend on anything outside itself.
echo "Linked libraries:"
otool -L "$APP/Contents/MacOS/ClearCall"
if otool -L "$APP/Contents/MacOS/ClearCall" | grep -E "/opt/homebrew|/usr/local|vendor/"; then
  echo "error: binary links to a library that won't exist on other Macs" >&2
  exit 1
fi

# 3. Sign (ad-hoc unless a signing identity is provided) and zip.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements Resources/ClearCall.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/ClearCall-$VERSION.zip"
echo "Built $OUT/ClearCall-$VERSION.zip"
