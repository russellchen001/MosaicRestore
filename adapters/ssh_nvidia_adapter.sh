#!/bin/bash
set -u

ACTION=${1:-}
shift || true
PROFILE=""
JOB=""
INPUT=""
OUTPUT=""
DETECTOR="lada-yolo-v4"
RESTORER="basicvsrpp"
BACKEND="cuda"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) PROFILE=$2; shift 2 ;;
    --job) JOB=$2; shift 2 ;;
    --input) INPUT=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --detector) DETECTOR=$2; shift 2 ;;
    --restorer) RESTORER=$2; shift 2 ;;
    --backend) BACKEND=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$PROFILE" in
  ""|*[!A-Za-z0-9._-]*) echo "invalid profile" >&2; exit 2 ;;
esac

PROFILE_FILE="${MOSAIC_CLOUD_PROFILE_DIR:-$HOME/.config/mosaicrestore/profiles}/$PROFILE.conf"
[ -f "$PROFILE_FILE" ] || { echo "profile not found: $PROFILE_FILE" >&2; exit 2; }

SSH_HOST=""
SSH_USER=""
SSH_PORT="22"
SSH_KEY=""
REMOTE_ROOT=""
REMOTE_RUNNER=""
HOURLY_COST_USD=""
REALTIME_FACTOR="1"
while IFS='=' read -r key value; do
  case "$key" in
    host) SSH_HOST=$value ;;
    user) SSH_USER=$value ;;
    port) SSH_PORT=$value ;;
    key) SSH_KEY=${value/#\~/$HOME} ;;
    remote_root) REMOTE_ROOT=$value ;;
    runner) REMOTE_RUNNER=$value ;;
    hourly_cost_usd) HOURLY_COST_USD=$value ;;
    realtime_factor) REALTIME_FACTOR=$value ;;
  esac
done < "$PROFILE_FILE"

for value in "$SSH_HOST" "$SSH_USER" "$REMOTE_ROOT" "$REMOTE_RUNNER" "$HOURLY_COST_USD"; do
  [ -n "$value" ] || { echo "profile is missing a required value" >&2; exit 2; }
done

SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=15 -p "$SSH_PORT")
SCP_ARGS=(-o BatchMode=yes -o ConnectTimeout=15 -P "$SSH_PORT")
if [ -n "$SSH_KEY" ]; then
  SSH_ARGS+=(-i "$SSH_KEY")
  SCP_ARGS+=(-i "$SSH_KEY")
fi
TARGET="$SSH_USER@$SSH_HOST"
REMOTE_JOB="$REMOTE_ROOT/jobs/$JOB"

remote() {
  ssh "${SSH_ARGS[@]}" "$TARGET" "$1"
}

quote() {
  printf '%q' "$1"
}

case "$ACTION" in
  validate)
    command -v ssh >/dev/null && command -v scp >/dev/null || exit 3
    remote "test -x $(quote "$REMOTE_RUNNER") && mkdir -p $(quote "$REMOTE_ROOT/jobs") $(quote "$REMOTE_ROOT/engine-cache")"
    ;;
  upload)
    [ -n "$JOB" ] && [ -f "$INPUT" ] || exit 2
    remote "mkdir -p $(quote "$REMOTE_JOB")"
    scp "${SCP_ARGS[@]}" "$INPUT" "$TARGET:$REMOTE_JOB/input.mp4" >/dev/null
    ;;
  readiness)
    remote "$(quote "$REMOTE_RUNNER") preflight --detector lada-yolo-v4 --restorer basicvsrpp --backend $(quote "$BACKEND") --engine-cache $(quote "$REMOTE_ROOT/engine-cache")"
    ;;
  estimate)
    duration=$(remote "ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $(quote "$REMOTE_JOB/input.mp4")") || exit 4
    estimated=$(awk -v duration="$duration" -v factor="$REALTIME_FACTOR" 'BEGIN { printf "%.1f", duration * factor }')
    cost=$(awk -v seconds="$estimated" -v hourly="$HOURLY_COST_USD" 'BEGIN { printf "%.4f", seconds * hourly / 3600 }')
    printf 'estimated_seconds=%s\nestimated_cost_usd=%s\n' "$estimated" "$cost"
    ;;
  start)
    remote "$(quote "$REMOTE_RUNNER") start --job $(quote "$JOB") --input $(quote "$REMOTE_JOB/input.mp4") --output $(quote "$REMOTE_JOB/output.mp4") --detector $(quote "$DETECTOR") --restorer $(quote "$RESTORER") --backend $(quote "$BACKEND") --engine-cache $(quote "$REMOTE_ROOT/engine-cache")"
    ;;
  status)
    remote "$(quote "$REMOTE_RUNNER") status --job $(quote "$JOB")"
    ;;
  cancel)
    remote "$(quote "$REMOTE_RUNNER") cancel --job $(quote "$JOB")"
    ;;
  download)
    [ -n "$OUTPUT" ] || exit 2
    scp "${SCP_ARGS[@]}" "$TARGET:$REMOTE_JOB/output.mp4" "$OUTPUT" >/dev/null
    ;;
  *)
    echo "unknown action: $ACTION" >&2
    exit 2
    ;;
esac
