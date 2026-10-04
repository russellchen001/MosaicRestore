#!/bin/bash
set -u

ACTION=${1:-}
shift || true

JOB=""
INPUT=""
OUTPUT=""
DETECTOR=""
RESTORER=""
BACKEND=""
ENGINE_CACHE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --job) JOB=$2; shift 2 ;;
    --input) INPUT=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --detector) DETECTOR=$2; shift 2 ;;
    --restorer) RESTORER=$2; shift 2 ;;
    --backend) BACKEND=$2; shift 2 ;;
    --engine-cache) ENGINE_CACHE=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

LADA_ROOT=${MOSAIC_LADA_ROOT:-/workspace/mosaic-p4/lada-runtime}
LADA_CLI="$LADA_ROOT/.venv/bin/lada-cli"
WEIGHTS_DIR="$LADA_ROOT/model_weights"
DETECTION_WEIGHT="$WEIGHTS_DIR/lada_mosaic_detection_model_v4_fast.pt"
RESTORATION_WEIGHT="$WEIGHTS_DIR/lada_mosaic_restoration_model_generic_v1.2.pth"
CUDA_DEVICE=${MOSAIC_CUDA_DEVICE:-cuda:0}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

valid_job() {
  case "$JOB" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

job_dir() {
  [ -n "$INPUT" ] || return 1
  dirname "$INPUT"
}

write_state() {
  printf '%s\n' "$1" > "$(job_dir)/state"
}

case "$ACTION" in
  preflight)
    [ "$DETECTOR" = "lada-yolo-v4" ] || { echo "unsupported detector" >&2; exit 3; }
    [ "$RESTORER" = "basicvsrpp" ] || { echo "unsupported restorer" >&2; exit 3; }
    [ "$BACKEND" = "cuda" ] || { echo "unsupported backend" >&2; exit 3; }
    command -v nvidia-smi >/dev/null || exit 3
    command -v ffmpeg >/dev/null || exit 3
    command -v ffprobe >/dev/null || exit 3
    [ -x "$LADA_CLI" ] || exit 3
    [ -s "$DETECTION_WEIGHT" ] || exit 3
    [ -s "$RESTORATION_WEIGHT" ] || exit 3
    "$LADA_ROOT/.venv/bin/python" -c \
      "import torch; assert torch.cuda.is_available(); assert torch.cuda.get_device_name(0)" \
      >/dev/null || exit 3
    mkdir -p "$ENGINE_CACHE"
    printf 'gpu=ready\ndriver=ready\ncuda=ready\nruntime=ready\ndetector=ready\ncache_hit=true\n'
    ;;
  start)
    valid_job || exit 2
    [ -f "$INPUT" ] && [ -n "$OUTPUT" ] || exit 2
    [ "$DETECTOR" = "lada-yolo-v4" ] || exit 3
    [ "$RESTORER" = "basicvsrpp" ] || exit 3
    [ "$BACKEND" = "cuda" ] || exit 3
    DIR=$(job_dir) || exit 2
    mkdir -p "$DIR" "$ENGINE_CACHE"
    if [ -f "$DIR/pid" ] && kill -0 "$(cat "$DIR/pid")" 2>/dev/null; then
      exit 0
    fi
    printf 'pending\n' > "$DIR/state"
    nohup setsid "$SELF" _execute \
      --job "$JOB" --input "$INPUT" --output "$OUTPUT" \
      --detector "$DETECTOR" --restorer "$RESTORER" \
      --backend "$BACKEND" --engine-cache "$ENGINE_CACHE" \
      > "$DIR/launcher.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$DIR/pid"
    ;;
  _execute)
    valid_job || exit 2
    DIR=$(job_dir) || exit 2
    write_state running
    cd "$LADA_ROOT" || { write_state failed; exit 4; }
    export LADA_MODEL_WEIGHTS_DIR="$WEIGHTS_DIR"
    set +e
    "$LADA_CLI" \
      --input "$INPUT" \
      --output "$OUTPUT" \
      --device "$CUDA_DEVICE" \
      --fp16 \
      --mosaic-detection-model v4-fast \
      --mosaic-restoration-model basicvsrpp-v1.2 \
      --max-clip-length 60 \
      --encoder libx264 \
      --encoder-options '-crf 18 -preset fast' \
      > "$DIR/runtime.log" 2>&1
    STATUS=$?
    set -e
    if [ "$STATUS" -eq 0 ] && [ -s "$OUTPUT" ] && ffprobe -v error "$OUTPUT" >/dev/null 2>&1; then
      write_state succeeded
      touch "$ENGINE_CACHE/lada-v4-fast-basicvsrpp-v1.2.cuda.ready"
      exit 0
    fi
    printf '%s\n' "$STATUS" > "$DIR/exit-code"
    write_state failed
    exit "$STATUS"
    ;;
  status)
    valid_job || exit 2
    INPUT=${INPUT:-/dev/null}
    DIR=${MOSAIC_REMOTE_ROOT:-/workspace/mosaic-p4/cloud}/jobs/$JOB
    STATE=$(cat "$DIR/state" 2>/dev/null || echo pending)
    if [ "$STATE" = running ] && [ -f "$DIR/pid" ] && ! kill -0 "$(cat "$DIR/pid")" 2>/dev/null; then
      STATE=failed
      printf 'failed\n' > "$DIR/state"
    fi
    case "$STATE" in
      succeeded) printf 'state=succeeded\nprogress=100\n' ;;
      cancelled) printf 'state=cancelled\nprogress=0\n' ;;
      failed) printf 'state=failed\nprogress=0\nmessage=Lada CUDA runner failed\n' ;;
      running) printf 'state=running\nprogress=50\n' ;;
      *) printf 'state=pending\nprogress=0\n' ;;
    esac
    ;;
  cancel)
    valid_job || exit 2
    DIR=${MOSAIC_REMOTE_ROOT:-/workspace/mosaic-p4/cloud}/jobs/$JOB
    if [ -f "$DIR/pid" ]; then
      PID=$(cat "$DIR/pid")
      kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null || true
    fi
    printf 'cancelled\n' > "$DIR/state"
    rm -f "$DIR/output.mp4"
    ;;
  *)
    echo "unknown action: $ACTION" >&2
    exit 2
    ;;
esac
