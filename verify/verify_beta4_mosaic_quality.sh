#!/bin/bash

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LADA="${MOSAIC_LADA_SOURCE_DIR:-$ROOT/benchmark/lada-upstream}"
TMP="$(mktemp -d /tmp/mosaic-beta4-quality.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass() {
    echo "✓ $1"
}

fail() {
    echo "✗ $1"
    echo "FAIL Beta4 mosaic quality — $2"
    exit 1
}

if [ ! -x "$LADA/.venv/bin/python" ]; then
    fail "Lada behavior environment" "missing $LADA/.venv/bin/python"
fi

mkdir -p "$TMP/source"
cp -R "$LADA/lada" "$TMP/source/" ||
    fail "Isolated Lada source" "could not copy the external runtime source"

if patch --silent -p1 -d "$TMP/source" < "$ROOT/patches/lada-temporal-detector-hold.patch"; then
    pass "Beta4 temporal hold patch applies to the pinned external runtime"
else
    fail "Beta4 temporal hold patch" "patch does not apply cleanly to the pinned runtime"
fi

if patch --silent -p1 -d "$TMP/source" < "$ROOT/patches/lada-context-expansion.patch"; then
    pass "Beta4 context expansion patch applies to the pinned external runtime"
else
    fail "Beta4 context expansion patch" "patch does not apply cleanly to the pinned runtime"
fi

if PYTHONPATH="$TMP/source" "$LADA/.venv/bin/python" \
    "$ROOT/verify/beta4_temporal_hold_behavior.py" "$TMP/source"; then
    pass "Missed detections are held for two frames and reset by a real detection"
else
    fail "Temporal detector hold behavior" "the behavioral sequence did not satisfy the hold contract"
fi

if PYTHONPATH="$TMP/source" "$LADA/.venv/bin/python" \
    "$ROOT/verify/beta4_context_expansion_behavior.py" "$TMP/source"; then
    pass "Restoration context expands within its bound and clips at frame edges"
else
    fail "Context expansion behavior" "the crop did not expand safely or changed the Clip interface"
fi

if CARGO_TARGET_DIR="$TMP/target" cargo test \
    --manifest-path "$ROOT/core/Cargo.toml" --quiet -- --test-threads=1; then
    pass "Mosaic Core regression tests"
else
    fail "Mosaic Core regression tests" "existing Core behavior regressed"
fi

BETA4_RUNTIME="${MOSAIC_BETA4_RUNTIME_DIR:-$ROOT/work/lada-macos-runtime}"
SMOKE="$ROOT/benchmark/samples/p1_lada_smoke.mp4"

if [ -x "$BETA4_RUNTIME/lada-cli" ] && [ -s "$SMOKE" ]; then
    if ! CARGO_TARGET_DIR="$TMP/target" cargo build \
        --manifest-path "$ROOT/core/Cargo.toml" --quiet --bin mosaic-core; then
        fail "Beta4 Core build" "mosaic-core did not build"
    fi

    if "$TMP/target/debug/mosaic-core" \
        --provider local-lada \
        --provider-root "$BETA4_RUNTIME" \
        --input "$SMOKE" \
        --output "$TMP/restored.mp4" \
        > "$TMP/restore.log" 2>&1 && \
       "$BETA4_RUNTIME/_internal/bin/ffprobe" -v error "$TMP/restored.mp4" \
        > /dev/null 2>&1 && \
       "$BETA4_RUNTIME/_internal/bin/ffmpeg" -v error -i "$TMP/restored.mp4" \
        -f null - > /dev/null 2>&1; then
        pass "Frozen Beta4 runtime completes a readable Local/MPS restore"
    else
        tail -20 "$TMP/restore.log" >&2
        fail "Frozen Beta4 runtime smoke" "Local/MPS restore or media decode failed"
    fi
else
    echo "SKIP Frozen Beta4 runtime smoke — build output or smoke fixture is unavailable"
fi

echo "PASS Beta4 mosaic quality"
exit 0
