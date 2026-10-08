#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1
FAIL=0
ROOT=$(mktemp -d /tmp/mosaic-p5-verify.XXXXXX)
BUILD="$ROOT/build"
trap 'rm -rf "$ROOT"' EXIT

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; FAIL=1; }

if CARGO_TARGET_DIR="$BUILD" cargo test --manifest-path core/Cargo.toml --quiet -- --test-threads=1; then
  pass "Agent Cloud Computer Core behavior tests"
else
  fail "Agent Cloud Computer Core behavior tests"
fi

if CARGO_TARGET_DIR="$BUILD" cargo build --manifest-path core/Cargo.toml --quiet; then
  CORE="$BUILD/debug/mosaic-core"
  pass "P5 Core executable builds"
else
  fail "P5 Core executable build"
  CORE=""
fi

mkdir -p "$ROOT/remote"
cat > "$ROOT/adapter" <<'SH'
#!/bin/bash
action=$1
shift
profile="" session="" input="" output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) profile=$2; shift 2 ;;
    --session) session=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) shift 2 ;;
  esac
done
root="$(dirname "$0")/remote"
printf '%s\n' "$action" >> "$root/events"
case "$action" in
  validate)
    if [ "$profile" = bypass ]; then
      printf 'contract_version=1\ntransport=ssh\nruntime=direct-runner\n'
    elif [ "$profile" = offline ]; then
      printf 'error_kind=provider-unavailable\nmessage=agent-relay-offline\n' >&2
      exit 7
    else
      printf 'contract_version=1\ntransport=agent-gui\nruntime=ufo2\n'
    fi
    ;;
  open-session) printf 'session_id=fixture-session\ntransport=agent-gui\n' ;;
  readiness) printf 'session_id=%s\ntransport=agent-gui\nagent=ready\ndesktop=ready\ngpu=ready\napplication=ready\n' "$session" ;;
  upload) cp "$input" "$root/input.mp4" ;;
  estimate) printf 'estimated_seconds=2.0\nestimated_cost_usd=0.01\n' ;;
  start) printf 'state=running\ntransport=agent-gui\naction_receipt=fixture-screenshot-1\n' ;;
  status)
    count=0
    [ -f "$root/count" ] && count=$(cat "$root/count")
    count=$((count + 1))
    printf '%s' "$count" > "$root/count"
    [ "$count" -eq 1 ] && exit 8
    if [ -f "$root/hold" ]; then
      printf 'session_id=%s\ntransport=agent-gui\nstate=running\nprogress=40\ngui_actions=4\n' "$session"
    else
      printf 'session_id=%s\ntransport=agent-gui\nstate=succeeded\nprogress=100\ngui_actions=8\nresult_ready=true\n' "$session"
    fi
    ;;
  reconnect) printf 'session_id=%s\nagent=ready\n' "$session" ;;
  cancel) printf cancelled > "$root/cancelled" ;;
  download) cp "$root/input.mp4" "$output" ;;
  metadata) printf 'runtime=ufo2\nelapsed_seconds=2\nbilled_cost_usd=0.01\n' ;;
  cleanup) touch "$root/cleaned" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$ROOT/adapter"

write_config() {
  profile=$1
  path=$2
  cat > "$path" <<EOF
version=1
adapter=$ROOT/adapter
profile=$profile
status_retries=3
poll_millis=20
EOF
}

write_config fixture "$ROOT/agent-cloud.conf"
write_config bypass "$ROOT/bypass.conf"
write_config offline "$ROOT/offline.conf"

if ffmpeg -loglevel error -f lavfi -i color=c=black:s=64x64:d=1 -c:v libx264 -pix_fmt yuv420p "$ROOT/input.mp4"; then
  pass "Agent cloud fixture video created"
else
  fail "Agent cloud fixture video creation"
fi

if [ -n "$CORE" ] && \
   "$CORE" --provider agent-cloud-computer --agent-cloud-config "$ROOT/agent-cloud.conf" \
     --input "$ROOT/input.mp4" --output "$ROOT/output.mp4" > "$ROOT/run.log" 2>&1 && \
   ffprobe -v error "$ROOT/output.mp4" >/dev/null 2>&1; then
  pass "Configuration, session, readiness, upload, GUI launch, status and download"
else
  fail "Agent Cloud Computer lifecycle"
fi

if cmp -s "$ROOT/input.mp4" "$ROOT/output.mp4" && \
   grep -q '^reconnect$' "$ROOT/remote/events" && \
   grep -q 'agent-session-reconnecting' "$ROOT/run.log" && \
   grep -q 'AGENT_CLOUD runtime=ufo2' "$ROOT/run.log" && \
   [ -f "$ROOT/remote/cleaned" ]; then
  pass "GUI evidence, same-session reconnect, metadata and cleanup"
else
  fail "Agent evidence, reconnect, metadata or cleanup"
fi

if "$CORE" --provider agent-cloud-computer --agent-cloud-config "$ROOT/bypass.conf" \
     --input "$ROOT/input.mp4" --output "$ROOT/bypass-output.mp4" >/dev/null 2>&1; then
  fail "Direct SSH/runner bypass rejection"
else
  pass "Direct SSH/runner bypass rejection"
fi

rm -f "$ROOT/remote/count" "$ROOT/remote/cancelled" "$ROOT/cancelled-output.mp4"
touch "$ROOT/remote/hold"
"$CORE" --provider agent-cloud-computer --agent-cloud-config "$ROOT/agent-cloud.conf" \
  --input "$ROOT/input.mp4" --output "$ROOT/cancelled-output.mp4" \
  --cancel-file "$ROOT/cancel" > "$ROOT/cancel.log" 2>&1 &
PID=$!
sleep 0.25
touch "$ROOT/cancel"
if wait "$PID"; then STATUS=0; else STATUS=$?; fi
if [ "$STATUS" -ne 0 ] && [ -f "$ROOT/remote/cancelled" ] && \
   [ ! -e "$ROOT/cancelled-output.mp4" ] && [ -f "$ROOT/remote/cleaned" ]; then
  pass "Agent cancellation and cleanup"
else
  fail "Agent cancellation and cleanup"
fi
rm -f "$ROOT/remote/hold"

if "$CORE" --provider agent-cloud-computer --agent-cloud-config "$ROOT/offline.conf" \
     --input "$ROOT/input.mp4" --output "$ROOT/offline-output.mp4" > "$ROOT/offline.log" 2>&1; then
  fail "Structured provider error mapping"
elif grep -q 'ProviderUnavailable.*agent-relay-offline' "$ROOT/offline.log"; then
  pass "Structured provider error mapping"
else
  fail "Structured provider error mapping"
fi

if DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
   SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/swift-module-cache" \
   CLANG_MODULE_CACHE_PATH="$ROOT/clang-module-cache" \
   swift run --package-path desktop --scratch-path "$ROOT/swift-build" -c release \
     MosaicRestoreContractCheck >/dev/null; then
  pass "Desktop Advanced provider contract"
else
  fail "Desktop Advanced provider contract"
fi

if PYTHONPYCACHEPREFIX="$ROOT/python-cache" python3 -m py_compile \
     adapters/http_agent_cloud_controller.py adapters/windows_gui_agent.py; then
  pass "Standalone controller and Windows GUI agent load"
else
  fail "Standalone controller or Windows GUI agent load"
fi

mkdir -p "$ROOT/agent-profiles"
cat > "$ROOT/fake-controller" <<'SH'
#!/bin/bash
action=$1
shift
printf '%s\n' "$action" >> "$(dirname "$0")/forwarded-events"
if [ "$action" = validate ]; then
  printf 'contract_version=1\ntransport=agent-gui\nruntime=windows-uia\n'
else
  printf 'forwarded=true\n'
fi
SH
chmod +x "$ROOT/fake-controller"
cat > "$ROOT/agent-profiles/fixture.conf" <<EOF
controller=$ROOT/fake-controller
controller_profile=$ROOT/http-profile.conf
EOF
if MOSAIC_AGENT_CLOUD_PROFILE_DIR="$ROOT/agent-profiles" \
     adapters/agent_cloud_adapter.sh validate --profile fixture > "$ROOT/forwarded.log" && \
   grep -q 'transport=agent-gui' "$ROOT/forwarded.log" && \
   grep -q '^validate$' "$ROOT/forwarded-events"; then
  pass "External controller adapter forwarding"
else
  fail "External controller adapter forwarding"
fi

if [ -n "${MOSAIC_AGENT_CLOUD_CONFIG:-}" ] && \
   [ -f "${MOSAIC_AGENT_CLOUD_CONFIG:-}" ] && \
   [ -s benchmark/samples/p1_lada_smoke.mp4 ]; then
  REAL_OUTPUT="benchmark/results/p5_agent_cloud_restored.mp4"
  rm -f "$REAL_OUTPUT"
  if "$CORE" --provider agent-cloud-computer \
       --agent-cloud-config "$MOSAIC_AGENT_CLOUD_CONFIG" \
       --input benchmark/samples/p1_lada_smoke.mp4 --output "$REAL_OUTPUT" \
       > "$ROOT/real.log" 2>&1 && \
     grep -q 'agent-gui-started' "$ROOT/real.log" && \
     grep -q 'AGENT_CLOUD runtime=' "$ROOT/real.log" && \
     ffprobe -v error "$REAL_OUTPUT" >/dev/null 2>&1; then
    pass "Real remote Agent Cloud Computer GUI end-to-end"
  else
    fail "Real remote Agent Cloud Computer GUI end-to-end"
  fi
else
  echo "SKIP real Agent Cloud Computer E2E — MOSAIC_AGENT_CLOUD_CONFIG is not available"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS P5 Agent Cloud Computer"
  exit 0
fi
echo "FAIL P5 Agent Cloud Computer"
exit 1
