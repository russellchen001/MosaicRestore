#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LADA="${MOSAIC_LADA_SOURCE_DIR:-$ROOT/benchmark/lada-upstream}"
OUT="${MOSAIC_LADA_RUNTIME_DIR:-$ROOT/work/lada-macos-runtime}"

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

cp \
  "$LADA/model_weights/lada_mosaic_detection_model_v4_fast.pt" \
  "$OUT/_internal/model_weights/"

cp \
  "$LADA/model_weights/lada_mosaic_restoration_model_generic_v1.2.pth" \
  "$OUT/_internal/model_weights/"

cp \
  "$LADA/LICENSE.md" \
  "$OUT/THIRD_PARTY_NOTICES/LADA-LICENSE.md"

cp \
  "$LADA/model_weights/lada_mosaic_detection_model_v4_fast.pt.license" \
  "$OUT/THIRD_PARTY_NOTICES/lada_mosaic_detection_model_v4_fast.pt.license"

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
  "detector": "lada_mosaic_detection_model_v4_fast.pt",
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
