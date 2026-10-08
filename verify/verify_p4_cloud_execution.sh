#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
FAIL=0
ROOT=$(mktemp -d /tmp/mosaic-p4-verify.XXXXXX)
BUILD="$ROOT/build"
trap 'rm -rf "$ROOT"' EXIT

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; FAIL=1; }

if CARGO_TARGET_DIR="$BUILD" cargo test --manifest-path core/Cargo.toml --quiet -- --test-threads=1; then
  pass "Cloud contract behavior tests"
else
  fail "Cloud contract behavior tests"
fi

if CARGO_TARGET_DIR="$BUILD" cargo build --manifest-path core/Cargo.toml --quiet; then
  CORE="$BUILD/debug/mosaic-core"
  pass "P4 Core executable builds"
else
  fail "P4 Core executable build"
  CORE=""
fi

mkdir -p "$ROOT/remote"
cat > "$ROOT/adapter" <<'SH'
#!/bin/bash
action=$1
shift
job="" input="" output="" detector="" restorer="" backend=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --job) job=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --detector) detector=$2; shift 2 ;;
    --restorer) restorer=$2; shift 2 ;;
    --backend) backend=$2; shift 2 ;;
    *) shift 2 ;;
  esac
done
root="$(dirname "$0")/remote"
printf '%s\n' "$action" >> "$root/events"
case "$action" in
  validate) exit 0 ;;
  upload) cp "$input" "$root/input.mp4" ;;
  readiness) printf 'gpu=ready\ndriver=ready\ncuda=ready\nruntime=ready\ndetector=ready\ncache_hit=true\n' ;;
  estimate) printf 'estimated_seconds=2.0\nestimated_cost_usd=0.01\n' ;;
  start)
    [ "$detector" = lada-yolo-v4 ] && [ "$restorer" = basicvsrpp ] && [ "$backend" = cuda ] || exit 7
    printf running > "$root/state"
    ;;
  status)
    count=0
    [ -f "$root/count" ] && count=$(cat "$root/count")
    count=$((count + 1))
    printf '%s' "$count" > "$root/count"
    [ "$count" -eq 1 ] && exit 8
    if [ -f "$root/hold" ]; then
      printf 'state=running\nprogress=40\n'
    else
      printf 'state=succeeded\nprogress=100\n'
    fi
    ;;
  cancel) printf cancelled > "$root/state" ;;
  download) cp "$root/input.mp4" "$output" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$ROOT/adapter"
cat > "$ROOT/cloud.conf" <<EOF
version=1
adapter=$ROOT/adapter
profile=fixture
status_retries=3
poll_millis=20
EOF

ffmpeg -loglevel error -f lavfi -i color=c=black:s=64x64:d=1 -c:v libx264 -pix_fmt yuv420p "$ROOT/input.mp4" || fail "Create cloud fixture video"

if [ -n "$CORE" ] && "$CORE" --provider cloud-nvidia --cloud-config "$ROOT/cloud.conf" --input "$ROOT/input.mp4" --output "$ROOT/output.mp4" > "$ROOT/run.log" 2>&1 && ffprobe -v error "$ROOT/output.mp4" >/dev/null 2>&1; then
  pass "Configuration, upload, readiness, remote start, recovery and download"
else
  fail "Cloud execution lifecycle"
fi

if cmp -s "$ROOT/input.mp4" "$ROOT/output.mp4" && grep -q 'runtime-cache-hit' "$ROOT/run.log" && grep -q 'CLOUD estimated_seconds=2.0 estimated_cost_usd=0.01' "$ROOT/run.log"; then
  pass "Runtime cache hit, cost estimate and result integrity"
else
  fail "Cache, estimate or result integrity"
fi

touch "$ROOT/remote/hold"
rm -f "$ROOT/remote/count" "$ROOT/cancelled-output.mp4"
"$CORE" --provider cloud-nvidia --cloud-config "$ROOT/cloud.conf" --input "$ROOT/input.mp4" --output "$ROOT/cancelled-output.mp4" --cancel-file "$ROOT/cancel" > "$ROOT/cancel.log" 2>&1 &
PID=$!
sleep 0.2
touch "$ROOT/cancel"
if wait "$PID"; then STATUS=0; else STATUS=$?; fi
if [ "$STATUS" -ne 0 ] && [ "$(cat "$ROOT/remote/state" 2>/dev/null)" = cancelled ] && [ ! -e "$ROOT/cancelled-output.mp4" ]; then
  pass "Remote cancellation"
else
  fail "Remote cancellation"
fi

printf 'version=1\nprofile=broken\n' > "$ROOT/invalid.conf"
if "$CORE" --provider cloud-nvidia --cloud-config "$ROOT/invalid.conf" --input "$ROOT/input.mp4" --output "$ROOT/invalid-output.mp4" >/dev/null 2>&1; then
  fail "Invalid cloud configuration rejection"
else
  pass "Invalid cloud configuration rejection"
fi

if [ -n "${MOSAIC_CLOUD_CONFIG:-}" ] && [ -f "${MOSAIC_CLOUD_CONFIG:-}" ] && [ -s "benchmark/samples/p1_lada_smoke.mp4" ]; then
  REAL_OUTPUT="benchmark/results/p4_cloud_restored.mp4"
  rm -f "$REAL_OUTPUT"
  if "$CORE" --provider cloud-nvidia --cloud-config "$MOSAIC_CLOUD_CONFIG" --input benchmark/samples/p1_lada_smoke.mp4 --output "$REAL_OUTPUT" > "$ROOT/real.log" 2>&1 && ffprobe -v error "$REAL_OUTPUT" >/dev/null 2>&1; then
    pass "Real NVIDIA Lada CUDA end-to-end"
  else
    fail "Real NVIDIA Lada CUDA end-to-end"
  fi
else
  echo "SKIP real NVIDIA E2E — MOSAIC_CLOUD_CONFIG is not available"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS P4 Cloud Execution"
  exit 0
fi
echo "FAIL P4 Cloud Execution"
exit 1
