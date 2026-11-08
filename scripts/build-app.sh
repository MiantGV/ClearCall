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
# Abseil (bundled into the WebRTC library) installs its headers into include/ directly.
CFLAGS="$(pkg-config --cflags webrtc-audio-processing-2) -I$ROOT/vendor/webrtc/include"
LIBS="-L$ROOT/vendor/webrtc/lib -lwebrtc-audio-processing-2 -framework CoreFoundation -framework Foundation"
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
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# The app must not depend on anything outside itself.
echo "Linked libraries:"
otool -L "$APP/Contents/MacOS/ClearCall"
if otool -L "$APP/Contents/MacOS/ClearCall" | grep -E "/opt/homebrew|/usr/local|vendor/"; then
  echo "error: binary links to a library that won't exist on other Macs" >&2
  exit 1
fi

# 3. Sign and zip.
# macOS remembers microphone / system audio permission by the app's "designated requirement".
# Without a certificate that would be the build's unique hash, so every update would ask again.
# We pin it to the bundle identifier so updates keep their permissions.
# If a certificate is provided later (SIGN_IDENTITY), its default requirement is used instead.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --entitlements Resources/ClearCall.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --options runtime --entitlements Resources/ClearCall.entitlements --sign - \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
codesign --verify --strict --verbose "$APP"
echo "Designated requirement:"
codesign -d -r- "$APP" 2>&1 | grep designated

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/ClearCall-$VERSION.zip"
echo "Built $OUT/ClearCall-$VERSION.zip"
