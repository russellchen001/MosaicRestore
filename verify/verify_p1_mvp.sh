#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
FAIL=0
SMOKE="benchmark/samples/p1_lada_smoke.mp4"
OUTPUT="benchmark/results/p1_lada_smoke_restored.mp4"
LADA_ROOT="benchmark/lada-upstream"
RUNTIME_ROOT="${MOSAIC_LADA_RUNTIME_DIR:-work/lada-macos-runtime}"

if cargo test --manifest-path core/Cargo.toml --quiet; then
  echo "✓ Core, provider, progress, cancellation and error mapping"
else
  echo "✗ Core behavior tests"
  FAIL=1
fi

if cargo build --manifest-path core/Cargo.toml --quiet --bin mosaic-core; then
  echo "✓ CLI runner builds"
else
  echo "✗ CLI runner build"
  FAIL=1
fi

if [ -x "$LADA_ROOT/.venv/bin/lada-cli" ] && \
   "$LADA_ROOT/.venv/bin/lada-cli" --list-devices 2>&1 | grep -q 'mps'; then
  echo "✓ Lada reports Apple MPS"
else
  echo "✗ Lada Apple MPS unavailable"
  FAIL=1
fi

mkdir -p benchmark/samples benchmark/results
rm -f "$SMOKE" "$OUTPUT"
if ffmpeg -v error -y -ss 0 -i benchmark/samples/baseline.mp4 -t 0.5 \
    -vf 'scale=320:-2' -an "$SMOKE"; then
  echo "✓ short smoke video created"
else
  echo "✗ short smoke video creation"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ] && \
   core/target/debug/mosaic-core \
     --provider local-lada \
     --provider-root "$RUNTIME_ROOT" \
     --input "$SMOKE" \
     --output "$OUTPUT"; then
  echo "✓ real Local Lada/MPS restore"
else
  echo "✗ real Local Lada/MPS restore"
  FAIL=1
fi

if [ -s "$OUTPUT" ] && ffprobe -v error "$OUTPUT" >/dev/null 2>&1; then
  echo "✓ restored output is a readable video"
else
  echo "✗ restored output validation"
  FAIL=1
fi

for ignored_path in benchmark/samples benchmark/results benchmark/lada-upstream core/target; do
  if ! git check-ignore -q "$ignored_path"; then
    echo "✗ required path is not ignored: $ignored_path"
    FAIL=1
  fi
done
if [ "$FAIL" -eq 0 ]; then
  echo "✓ generated and upstream directories remain ignored"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS P1 Mosaic Core MVP"
  exit 0
fi

echo "FAIL P1 Mosaic Core MVP"
exit 1
