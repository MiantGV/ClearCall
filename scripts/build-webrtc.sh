#!/bin/bash
# Builds WebRTC's audio processing library (AEC3) as static libraries into ./vendor/webrtc.
# Source: https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing (BSD licence)
set -euo pipefail

WAP_VERSION="${WAP_VERSION:-v2.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build-webrtc"
PREFIX="$ROOT/vendor/webrtc"

if [ -f "$PREFIX/.built-$WAP_VERSION" ]; then
  echo "WebRTC audio processing $WAP_VERSION already built."
  exit 0
fi

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK"
git clone --depth 1 --branch "$WAP_VERSION" \
  https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$WORK/src"

cd "$WORK/src"
meson setup "$WORK/build" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --buildtype=release \
  --default-library=static \
  --wrap-mode=forcefallback \
  -Dcpp_args="-arch arm64 -mmacosx-version-min=14.4" \
  -Dc_args="-arch arm64 -mmacosx-version-min=14.4" \
  -Dcpp_link_args="-arch arm64" \
  -Dc_link_args="-arch arm64"
meson compile -C "$WORK/build"
meson install -C "$WORK/build"
touch "$PREFIX/.built-$WAP_VERSION"
echo "Installed into $PREFIX"
ls -R "$PREFIX/lib" | head -50
