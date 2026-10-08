#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LADA="${MOSAIC_LADA_SOURCE_DIR:-$ROOT/benchmark/lada-upstream}"
OUT="${MOSAIC_LADA_RUNTIME_DIR:-$ROOT/work/lada-macos-runtime}"
TEMPORAL_PATCH="$ROOT/patches/lada-temporal-detector-hold.patch"
CONTEXT_PATCH="$ROOT/patches/lada-context-expansion.patch"
TEMPORAL_TEST="$ROOT/verify/beta4_temporal_hold_behavior.py"
CONTEXT_TEST="$ROOT/verify/beta4_context_expansion_behavior.py"
TEMPORAL_PATCH_APPLIED=0
CONTEXT_PATCH_APPLIED=0

restore_lada_source() {
    if [ "$CONTEXT_PATCH_APPLIED" -eq 1 ]; then
        git -C "$LADA" apply --reverse "$CONTEXT_PATCH" || {
            echo "FAIL — could not remove the Beta4 context expansion patch"
            return 1
        }
    fi
    if [ "$TEMPORAL_PATCH_APPLIED" -eq 1 ]; then
        git -C "$LADA" apply --reverse "$TEMPORAL_PATCH" || {
            echo "FAIL — could not remove the Beta4 temporal hold patch"
            return 1
        }
    fi
}

trap restore_lada_source EXIT

echo "===== Lada source ====="
echo "$LADA"

if [ ! -d "$LADA/.git" ]; then
    echo "FAIL — Lada source checkout missing"
    exit 1
fi

if [ ! -x "$LADA/.venv/bin/python" ]; then
    echo "FAIL — Lada Python environment missing"
    exit 1
fi

if ! "$LADA/.venv/bin/python" -m PyInstaller --version >/dev/null 2>&1; then
    echo "Installing PyInstaller into Lada build environment..."
    uv pip install \
      --python "$LADA/.venv/bin/python" \
      pyinstaller || exit 1
fi

if ! git -C "$LADA" apply --check "$TEMPORAL_PATCH"; then
    echo "FAIL — Beta4 temporal detector hold patch does not apply cleanly"
    exit 1
fi

git -C "$LADA" apply "$TEMPORAL_PATCH" || exit 1
TEMPORAL_PATCH_APPLIED=1

if ! git -C "$LADA" apply --check "$CONTEXT_PATCH"; then
    echo "FAIL — Beta4 context expansion patch does not apply cleanly"
    exit 1
fi

git -C "$LADA" apply "$CONTEXT_PATCH" || exit 1
CONTEXT_PATCH_APPLIED=1

if ! PYTHONPATH="$LADA" "$LADA/.venv/bin/python" "$TEMPORAL_TEST" "$LADA"; then
    echo "FAIL — Beta4 temporal detector hold behavior"
    exit 1
fi

if ! PYTHONPATH="$LADA" "$LADA/.venv/bin/python" "$CONTEXT_TEST" "$LADA"; then
    echo "FAIL — Beta4 context expansion behavior"
    exit 1
fi

echo
echo "===== Build upstream standalone CLI ====="

cd "$LADA" || exit 1

"$LADA/.venv/bin/python" -m PyInstaller \
  --noconfirm \
  packaging/macOS/lada.spec

PYI=$?

if [ "$PYI" -ne 0 ]; then
    echo "FAIL — PyInstaller build failed"
    exit 1
fi

if [ ! -x "$LADA/dist/cli/lada-cli" ]; then
    echo "FAIL — standalone lada-cli missing"
    exit 1
fi

echo
echo "===== Assemble MosaicRestore runtime ====="

rm -rf "$OUT"
mkdir -p "$OUT"

cp -R "$LADA/dist/cli/." "$OUT/"

# Frozen Lada's runtime hook forces LADA_MODEL_WEIGHTS_DIR to:
#   <runtime>/_internal/model_weights
#
# Therefore production model files MUST live there.
rm -rf "$OUT/model_weights"
rm -rf "$OUT/_internal/model_weights"

mkdir -p \
  "$OUT/_internal/model_weights" \
  "$OUT/THIRD_PARTY_NOTICES"

ACCURATE_NAME="lada_mosaic_detection_model_v4_accurate.pt"
ACCURATE_SHA="c244d7e49d8f88e264b8dc15f91fb21f5908ad8fb6f300b7bc88462d0801bc1f"
MODEL_CACHE="$ROOT/work/model-cache"
ACCURATE_CACHE="$MODEL_CACHE/$ACCURATE_NAME"

mkdir -p "$MODEL_CACHE"

if [ ! -f "$ACCURATE_CACHE" ]; then
    echo "Downloading official Lada v4-accurate detector..."

    curl -L \
      "https://huggingface.co/ladaapp/lada/resolve/main/$ACCURATE_NAME?download=true" \
      -o "$ACCURATE_CACHE" || exit 1
fi

ACTUAL_ACCURATE_SHA="$(
  shasum -a 256 "$ACCURATE_CACHE" |
  awk '{print $1}'
)"

if [ "$ACTUAL_ACCURATE_SHA" != "$ACCURATE_SHA" ]; then
    echo "FAIL — v4-accurate checksum mismatch"
    echo "expected=$ACCURATE_SHA"
    echo "actual=$ACTUAL_ACCURATE_SHA"
    exit 1
fi

cp \
  "$LADA/model_weights/lada_mosaic_detection_model_v4_fast.pt" \
  "$OUT/_internal/model_weights/"

cp \
  "$ACCURATE_CACHE" \
  "$OUT/_internal/model_weights/$ACCURATE_NAME"

cp \
  "$LADA/model_weights/lada_mosaic_restoration_model_generic_v1.2.pth" \
  "$OUT/_internal/model_weights/"

cp \
  "$LADA/LICENSE.md" \
  "$OUT/THIRD_PARTY_NOTICES/LADA-LICENSE.md"

cp \
  "$LADA/model_weights/lada_mosaic_detection_model_v4_fast.pt.license" \
  "$OUT/THIRD_PARTY_NOTICES/lada_mosaic_detection_model_v4_fast.pt.license"

if [ -f "$LADA/model_weights/lada_mosaic_detection_model_v4_accurate.pt.license" ]; then
    cp \
      "$LADA/model_weights/lada_mosaic_detection_model_v4_accurate.pt.license" \
      "$OUT/THIRD_PARTY_NOTICES/lada_mosaic_detection_model_v4_accurate.pt.license"
else
    echo "FAIL — v4-accurate model license file missing"
    exit 1
fi

cp \
  "$LADA/model_weights/lada_mosaic_restoration_model_generic_v1.2.pth.license" \
  "$OUT/THIRD_PARTY_NOTICES/lada_mosaic_restoration_model_generic_v1.2.pth.license"

COMMIT="$(git -C "$LADA" rev-parse HEAD)"

printf '%s\n' "$COMMIT" \
  > "$OUT/THIRD_PARTY_NOTICES/LADA-COMMIT.txt"

cat > "$OUT/THIRD_PARTY_NOTICES/LADA-SOURCE.md" <<EOF
# Lada source

MosaicRestore distributes Lada as an external standalone runtime.

Upstream:
https://github.com/ladaapp/lada

Exact source revision:

$COMMIT

See LADA-LICENSE.md and the accompanying model license files.
EOF

cat > "$OUT/runtime.json" <<EOF
{
  "runtime": "lada",
  "source_commit": "$COMMIT",
  "platform": "macOS",
  "architecture": "arm64",
  "detector_default": "lada_mosaic_detection_model_v4_accurate.pt",
  "detector_fast": "lada_mosaic_detection_model_v4_fast.pt",
  "temporal_detector_hold_frames": 2,
  "restoration_context_ratio": 0.12,
  "restorer": "lada_mosaic_restoration_model_generic_v1.2.pth"
}
EOF

chmod +x "$OUT/lada-cli"

echo
echo "===== Runtime size ====="
du -sh "$OUT"

echo
echo "===== Production model inventory ====="
find "$OUT" \
  -type f \
  \( -name '*.pt' -o -name '*.pth' \) \
  -print

echo
echo "===== Verify standalone CLI ====="

"$OUT/lada-cli" --help >/dev/null 2>&1
CLI=$?

echo "cli_status=$CLI"

if [ "$CLI" -ne 0 ]; then
    echo "FAIL — standalone CLI does not launch"
    exit 1
fi

echo "PASS — reproducible Lada runtime assembled"
