#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
FAIL=0
APP="desktop/build/MosaicRestore.app"
SMOKE="benchmark/samples/p1_lada_smoke.mp4"
OUTPUT="benchmark/results/p2_desktop_restored.mp4"
LADA_ROOT="$APP/Contents/Resources/Runtime/Lada"
FIXTURE_ROOT=$(mktemp -d /tmp/mosaic-p2-verify.XXXXXX)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

if desktop/build_app.sh >/dev/null; then
  echo "✓ Desktop app bundle builds"
else
  echo "✗ Desktop app bundle build"
  FAIL=1
fi

if desktop/.build/release/MosaicRestoreContractCheck; then
  echo "✓ Desktop behavior contract"
else
  echo "✗ Desktop behavior contract"
  FAIL=1
fi

if [ -x "$APP/Contents/MacOS/MosaicRestore" ] && \
   [ -x "$APP/Contents/Resources/mosaic-core" ] && \
   codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "✓ App bundle contains signed Desktop and Mosaic Core executables"
else
  echo "✗ App bundle structure or signature"
  FAIL=1
fi

BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$BUNDLE_ID" = "com.russellchen.mosaicrestore" ]; then
  echo "✓ App bundle metadata is readable"
else
  echo "✗ App bundle metadata"
  FAIL=1
fi

mkdir -p "$FIXTURE_ROOT/lada/.venv/bin"
cat > "$FIXTURE_ROOT/lada/.venv/bin/lada-cli" <<'SH'
#!/bin/bash
sleep 10
exit 0
SH
chmod +x "$FIXTURE_ROOT/lada/.venv/bin/lada-cli"
printf 'video' > "$FIXTURE_ROOT/input.mp4"
"$APP/Contents/Resources/mosaic-core" \
  --provider local-lada \
  --provider-root "$FIXTURE_ROOT/lada" \
  --input "$FIXTURE_ROOT/input.mp4" \
  --output "$FIXTURE_ROOT/output.mp4" \
  --cancel-file "$FIXTURE_ROOT/cancel" \
  >"$FIXTURE_ROOT/cancel.log" 2>&1 &
CANCEL_PID=$!
sleep 1
touch "$FIXTURE_ROOT/cancel"
if wait "$CANCEL_PID"; then
  CANCEL_STATUS=0
else
  CANCEL_STATUS=$?
fi
if [ "$CANCEL_STATUS" -ne 0 ] && [ ! -e "$FIXTURE_ROOT/output.mp4" ]; then
  echo "✓ Cancel stops Core work without leaving output"
else
  echo "✗ Cancel behavior"
  FAIL=1
fi

rm -f "$OUTPUT"
if [ -s "$SMOKE" ] && \
   "$APP/Contents/Resources/mosaic-core" \
     --provider local-lada \
     --provider-root "$LADA_ROOT" \
     --input "$SMOKE" \
     --output "$OUTPUT" >/dev/null && \
   [ -s "$OUTPUT" ] && ffprobe -v error "$OUTPUT" >/dev/null 2>&1; then
  echo "✓ Packaged Desktop Core completes a real Local Lada/MPS restore"
else
  echo "✗ Packaged Desktop Local Lada/MPS restore"
  FAIL=1
fi

if command -v nvidia-smi >/dev/null 2>&1 && \
   [ -n "${MOSAIC_JASNA_RUNNER:-}" ] && [ -x "${MOSAIC_JASNA_RUNNER:-}" ]; then
  echo "✓ NVIDIA environment and Jasna runner are available for external E2E"
else
  echo "SKIP real NVIDIA/Jasna E2E — NVIDIA runtime is unavailable on this Mac"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS P2 Desktop App"
  exit 0
fi

echo "FAIL P2 Desktop App"
exit 1
