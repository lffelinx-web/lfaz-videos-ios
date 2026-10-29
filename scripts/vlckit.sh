#!/bin/bash
# Downloads the official MobileVLCKit from VideoLAN, checks its SHA-256 and
# leaves Vendor/MobileVLCKit.xcframework ready for XcodeGen.
# URL and checksum come from VideoLAN's own podspec (MobileVLCKit 3.7.4).
set -euo pipefail
cd "$(dirname "$0")/.."
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz"
SHA256="c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52"
ARCHIVE="Vendor/MobileVLCKit.tar.xz"

mkdir -p Vendor
if [ -d Vendor/MobileVLCKit.xcframework ]; then echo "VLCKit ya está preparado."; exit 0; fi
if [ ! -f "$ARCHIVE" ] || ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c --status; then
  curl -fL --retry 3 -o "$ARCHIVE" "$URL"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c
rm -rf Vendor/extract && mkdir -p Vendor/extract
tar -xJf "$ARCHIVE" -C Vendor/extract
FRAMEWORK=$(find Vendor/extract -maxdepth 4 -type d -name MobileVLCKit.xcframework | head -1)
[ -n "$FRAMEWORK" ] || { echo "No se encontró MobileVLCKit.xcframework en el archivo." >&2; exit 1; }
mv "$FRAMEWORK" Vendor/MobileVLCKit.xcframework
# The device slice still carries armv7/armv7s; iOS 17 only needs arm64.
for binary in Vendor/MobileVLCKit.xcframework/ios-arm64*/MobileVLCKit.framework/MobileVLCKit; do
  case "$binary" in *simulator*) continue ;; esac
  if [ "$(lipo -archs "$binary")" != "arm64" ]; then lipo -thin arm64 "$binary" -output "$binary.thin" && mv "$binary.thin" "$binary"; fi
done
rm -rf Vendor/extract
ls Vendor/MobileVLCKit.xcframework
file Vendor/MobileVLCKit.xcframework/ios-arm64*/MobileVLCKit.framework/MobileVLCKit
