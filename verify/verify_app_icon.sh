#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
APP="desktop/build/MosaicRestore.app"
ICON="$APP/Contents/Resources/MosaicRestore.icns"
LOG_DIR=$(mktemp -d /tmp/mosaic-app-icon.XXXXXX)
FAIL=0

cleanup() { rm -rf "$LOG_DIR"; }
trap cleanup EXIT
pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; FAIL=1; }

if desktop/build_app.sh >"$LOG_DIR/build.log" 2>&1; then
  pass "Release app bundle builds"
else
  fail "Release app bundle build failed"
fi

ICON_NAME=$(plutil -extract CFBundleIconFile raw "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$ICON_NAME" = "MosaicRestore.icns" ] && [ -s "$ICON" ]; then
  pass "Bundle metadata resolves the packaged icon"
else
  fail "Bundle icon metadata or resource is missing"
fi

if iconutil -c iconset "$ICON" -o "$LOG_DIR/MosaicRestore.iconset" 2>"$LOG_DIR/iconutil.log"; then
  pass "Packaged icon is a readable macOS icon family"
else
  fail "Packaged icon cannot be decoded"
fi

ICON_SIZES_VALID=1
for SPEC in "icon_16x16.png:16" "icon_16x16@2x.png:32" "icon_32x32.png:32" "icon_32x32@2x.png:64" "icon_128x128.png:128" "icon_128x128@2x.png:256" "icon_256x256.png:256" "icon_256x256@2x.png:512" "icon_512x512.png:512" "icon_512x512@2x.png:1024"; do
  FILE=${SPEC%%:*}
  SIZE=${SPEC##*:}
  WIDTH=$(sips -g pixelWidth "$LOG_DIR/MosaicRestore.iconset/$FILE" 2>/dev/null | tail -1 | tr -cd '0-9')
  HEIGHT=$(sips -g pixelHeight "$LOG_DIR/MosaicRestore.iconset/$FILE" 2>/dev/null | tail -1 | tr -cd '0-9')
  if [ "$WIDTH" != "$SIZE" ] || [ "$HEIGHT" != "$SIZE" ]; then ICON_SIZES_VALID=0; fi
done
[ "$ICON_SIZES_VALID" -eq 1 ] && pass "All standard and Retina icon sizes are present" || fail "One or more icon sizes are invalid"

if codesign --verify --deep --strict "$APP" 2>"$LOG_DIR/codesign.log"; then
  pass "Icon-bearing app bundle has a valid strict signature"
else
  fail "App bundle signature verification failed"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS MosaicRestore App Icon"
  exit 0
fi
echo "FAIL MosaicRestore App Icon — one or more executable checks failed"
exit 1
