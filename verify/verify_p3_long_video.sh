#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
FAIL=0
ROOT=$(mktemp -d /tmp/mosaic-p3-verify.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
CORE="core/target/debug/mosaic-core"

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; FAIL=1; }

if cargo test --manifest-path core/Cargo.toml --quiet -- --test-threads=1 && \
   cargo build --manifest-path core/Cargo.toml --quiet --bin mosaic-core; then
  pass "P3 Core behavior tests and CLI build"
else
  fail "P3 Core behavior tests or CLI build"
fi

if swift build --package-path desktop -c release >/dev/null && \
   desktop/.build/release/MosaicRestoreContractCheck >/dev/null; then
  pass "Desktop production queue contract"
else
  fail "Desktop production queue contract"
fi

mkdir -p "$ROOT/provider/.venv/bin" "$ROOT/media" "$ROOT/work"
cat > "$ROOT/provider/.venv/bin/lada-cli" <<'SH'
#!/bin/bash
root=$(cd "$(dirname "$0")/../../" && pwd)
input= output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
count=0
[ -f "$root/count" ] && count=$(<"$root/count")
count=$((count + 1))
printf '%s\n' "$count" > "$root/count"
if [ -f "$root/fail-once" ]; then
  rm "$root/fail-once"
  exit 19
fi
if [ -f "$root/slow-once" ] && [ "$count" -ge 2 ]; then
  rm "$root/slow-once"
  sleep 10
fi
if [ -f "$root/crash-wait-once" ] && [ "$count" -ge 2 ]; then
  rm "$root/crash-wait-once"
  parent=$PPID
  while kill -0 "$parent" 2>/dev/null; do sleep 0.1; done
  exit 29
fi
cp "$input" "$output"
SH
chmod +x "$ROOT/provider/.venv/bin/lada-cli"

if ffmpeg -v error -y -f lavfi -i testsrc=size=160x90:rate=10 -t 4 \
   -c:v libx264 -g 10 -keyint_min 10 -pix_fmt yuv420p "$ROOT/media/long.mp4" && \
   ffmpeg -v error -y -f lavfi -i color=c=blue:size=160x90:rate=10 -t 1 \
   -c:v libx264 -g 10 -pix_fmt yuv420p "$ROOT/media/second.mp4"; then
  pass "Short fixtures simulate a multi-chunk long workflow"
else
  fail "Fixture video creation"
fi

printf '0\n' > "$ROOT/provider/count"
touch "$ROOT/provider/slow-once"
"$CORE" --provider local-lada --provider-root "$ROOT/provider" \
  --production --chunk-seconds 1 --max-retries 0 --work-root "$ROOT/work" \
  --input "$ROOT/media/long.mp4" --output "$ROOT/media/resumed.mp4" \
  --cancel-file "$ROOT/cancel" >"$ROOT/cancel.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
  checkpoint=$(find "$ROOT/work" -name checkpoint.txt -type f -print -quit)
  if [ -n "$checkpoint" ] && grep -q '^completed=0$' "$checkpoint"; then break; fi
  sleep 0.1
done
touch "$ROOT/cancel"
if wait "$PID"; then cancel_status=0; else cancel_status=$?; fi
checkpoint=$(find "$ROOT/work" -name checkpoint.txt -type f -print -quit)
if [ "$cancel_status" -ne 0 ] && [ -n "$checkpoint" ] && \
   grep -q '^completed=0$' "$checkpoint" && [ ! -e "$ROOT/media/resumed.mp4" ]; then
  pass "Cancellation preserves one consistent resumable checkpoint"
else
  fail "Cancellation checkpoint consistency"
fi

rm -f "$ROOT/cancel"
if "$CORE" --provider local-lada --provider-root "$ROOT/provider" \
   --production --chunk-seconds 1 --max-retries 0 --work-root "$ROOT/work" \
   --input "$ROOT/media/long.mp4" --output "$ROOT/media/resumed.mp4" \
   >"$ROOT/resume.log" 2>&1 && grep -q 'checkpoint-resumed' "$ROOT/resume.log"; then
  pass "Checkpoint resumes completed chunks after interruption"
else
  fail "Checkpoint resume behavior"
fi

calls=$(<"$ROOT/provider/count")
if [ "$calls" -eq 5 ]; then
  pass "Four-chunk plan executes once and skips recovered work"
else
  fail "Chunk plan expected 5 total provider calls including the cancelled attempt, got $calls"
fi

duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$ROOT/media/resumed.mp4" 2>/dev/null || true)
if [ -n "$duration" ] && awk -v d="$duration" 'BEGIN { exit !(d >= 3.0 && d <= 5.0) }'; then
  pass "Final output is readable with reasonable duration"
else
  fail "Final output readability or duration"
fi

if [ ! -d "$ROOT/work" ] || [ -z "$(find "$ROOT/work" -mindepth 1 -print -quit)" ]; then
  pass "Successful completion cleans temporary task files"
else
  fail "Temporary task cleanup"
fi

printf '0\n' > "$ROOT/provider/count"
touch "$ROOT/provider/crash-wait-once"
"$CORE" --provider local-lada --provider-root "$ROOT/provider" \
  --production --chunk-seconds 1 --max-retries 0 --work-root "$ROOT/crash-work" \
  --input "$ROOT/media/long.mp4" --output "$ROOT/media/crash-resumed.mp4" \
  >"$ROOT/crash.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
  checkpoint=$(find "$ROOT/crash-work" -name checkpoint.txt -type f -print -quit 2>/dev/null)
  if [ -n "$checkpoint" ] && grep -q '^completed=0$' "$checkpoint" && \
     [ ! -e "$ROOT/provider/crash-wait-once" ]; then break; fi
  sleep 0.1
done
kill -9 "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
if "$CORE" --provider local-lada --provider-root "$ROOT/provider" \
   --production --chunk-seconds 1 --max-retries 0 --work-root "$ROOT/crash-work" \
   --input "$ROOT/media/long.mp4" --output "$ROOT/media/crash-resumed.mp4" \
   >"$ROOT/crash-resume.log" 2>&1 && \
   grep -q 'checkpoint-resumed' "$ROOT/crash-resume.log" && \
   ffprobe -v error "$ROOT/media/crash-resumed.mp4" >/dev/null 2>&1; then
  pass "Unexpected process death resumes from the last durable checkpoint"
else
  fail "Crash recovery behavior"
fi

rm -f "$ROOT/provider/count"
touch "$ROOT/provider/fail-once"
if "$CORE" --provider local-lada --provider-root "$ROOT/provider" \
   --production --chunk-seconds 2 --max-retries 1 --work-root "$ROOT/retry-work" \
   --input "$ROOT/media/second.mp4" --output "$ROOT/media/retried.mp4" \
   >"$ROOT/retry.log" 2>&1 && grep -q '^RETRY chunk=1 attempt=2$' "$ROOT/retry.log" && \
   ffprobe -v error "$ROOT/media/retried.mp4" >/dev/null 2>&1; then
  pass "Provider failure retries once and safely completes"
else
  fail "Failure retry behavior"
fi

if "$CORE" --provider local-lada --provider-root "$ROOT/provider" \
   --production --minimum-free-bytes 18446744073709551615 \
   --input "$ROOT/media/second.mp4" --output "$ROOT/media/no-space.mp4" \
   >"$ROOT/space.log" 2>&1; then
  fail "Disk-space preflight unexpectedly succeeded"
elif grep -q 'InsufficientDiskSpace' "$ROOT/space.log" && [ ! -e "$ROOT/media/no-space.mp4" ]; then
  pass "Insufficient disk space is rejected before output creation"
else
  fail "Disk-space preflight boundary"
fi

if "$CORE" --provider local-lada --provider-root "$ROOT/provider" \
   --production --chunk-seconds 2 --work-root "$ROOT/batch-work" \
   --input "$ROOT/media/second.mp4" --output "$ROOT/media/batch-a.mp4" \
   --input "$ROOT/media/second.mp4" --output "$ROOT/media/batch-b.mp4" \
   >"$ROOT/batch.log" 2>&1 && \
   grep -q '^QUEUE 1/2 Running ' "$ROOT/batch.log" && \
   grep -q '^QUEUE 1/2 Succeeded ' "$ROOT/batch.log" && \
   grep -q '^QUEUE 2/2 Running ' "$ROOT/batch.log" && \
   grep -q '^QUEUE 2/2 Succeeded ' "$ROOT/batch.log" && \
   ffprobe -v error "$ROOT/media/batch-a.mp4" >/dev/null 2>&1 && \
   ffprobe -v error "$ROOT/media/batch-b.mp4" >/dev/null 2>&1; then
  pass "Batch queue preserves order and terminal states"
else
  fail "Batch queue order or status"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS P3 Long Video Reliability & Production Workflow"
  exit 0
fi
echo "FAIL P3 Long Video Reliability & Production Workflow"
exit 1
