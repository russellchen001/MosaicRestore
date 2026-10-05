#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
APP="desktop/build/MosaicRestore.app"

cargo build --manifest-path core/Cargo.toml --release --quiet || exit 1
swift build --package-path desktop -c release >/dev/null || exit 1
DESKTOP_BIN_DIR="$(swift build --package-path desktop -c release --show-bin-path)" || exit 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DESKTOP_BIN_DIR/MosaicRestore" "$APP/Contents/MacOS/MosaicRestore"
cp core/target/release/mosaic-core "$APP/Contents/Resources/mosaic-core"

RUNTIME_SOURCE="${MOSAIC_LADA_RUNTIME_DIR:-$PWD/work/lada-macos-runtime}"

if [ ! -x "$RUNTIME_SOURCE/lada-cli" ]; then
    echo "Missing standalone Lada runtime: $RUNTIME_SOURCE/lada-cli" >&2
    return 1 2>/dev/null || false
fi

mkdir -p "$APP/Contents/Resources/Runtime"
cp -R "$RUNTIME_SOURCE" "$APP/Contents/Resources/Runtime/Lada"
chmod +x "$APP/Contents/Resources/Runtime/Lada/lada-cli"

CLOUD_ADAPTER="$PWD/desktop/.build/release/MosaicCloudAdapter"

if [ ! -x "$CLOUD_ADAPTER" ]; then
    echo "Missing native cloud adapter: $CLOUD_ADAPTER" >&2
    return 1 2>/dev/null || false
fi

mkdir -p "$APP/Contents/Resources/Cloud"
cp "$CLOUD_ADAPTER" "$APP/Contents/Resources/Cloud/mosaic-cloud-adapter"
chmod +x "$APP/Contents/Resources/Cloud/mosaic-cloud-adapter"

cp desktop/Resources/MosaicRestore.icns "$APP/Contents/Resources/MosaicRestore.icns"
cp desktop/Resources/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/MosaicRestore" "$APP/Contents/Resources/mosaic-core"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
