#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
APP="desktop/build/MosaicRestore.app"

cargo build --manifest-path core/Cargo.toml --release --quiet || exit 1
swift build --package-path desktop -c release >/dev/null || exit 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp desktop/.build/release/MosaicRestore "$APP/Contents/MacOS/MosaicRestore"
cp core/target/release/mosaic-core "$APP/Contents/Resources/mosaic-core"
cp desktop/Resources/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/MosaicRestore" "$APP/Contents/Resources/mosaic-core"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
