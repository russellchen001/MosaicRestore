#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${MOSAIC_P5_IMAGE:-mosaicrestore/p5-linux-desktop:20261004-rfb1}
case "${1:---offline}" in
  --build)
    ROOT=$(mktemp -d /private/tmp/mosaic-p5-context.XXXXXX)
    mkdir -p "$ROOT/adapters/linux-desktop" "$ROOT/verify"
    cp adapters/linux-desktop/* "$ROOT/adapters/linux-desktop/"
    cp adapters/windows_gui_agent.py adapters/linux_gui_agent.py "$ROOT/adapters/"
    cp verify/p5_desktop_reconnect.py verify/p5_linux_fixture_server.py verify/p5_linux_fixture_task.py verify/p5_local_cpu_server.py verify/run_p5_linux.py "$ROOT/verify/"
    cp verify/p5_runtime_guards.py verify/p5_desktop_probe.py "$ROOT/verify/"
    docker build --platform linux/amd64 --build-arg MODEL_REVISION=bcf461d46d9a98981fc64b815df5178f42215cdf \
      -t mosaicrestore/p5-linux-runtime:20261004 -f "$ROOT/adapters/linux-desktop/Dockerfile.runtime" "$ROOT"
    docker build --platform linux/amd64 -t "$IMAGE" -f "$ROOT/adapters/linux-desktop/Dockerfile" "$ROOT"
    echo 'PASS P5 amd64 image build (GPU acceptance NOT RUN)'
    ;;
  --offline|--local-desktop)
    OUT=${2:?absolute new evidence directory required}
    mkdir -p "$OUT"
    NAME=mosaic-p5-offline-$(date +%s)
    TOKEN=$(openssl rand -hex 32)
    PASS=$(openssl rand -hex 4)
    SERVER=/opt/p5/p5_linux_fixture_server.py
    MODE=--offline
    if [ "$1" = --local-desktop ]; then SERVER=/opt/p5/p5_local_cpu_server.py; MODE=--local-cpu; fi
    trap 'docker stop -t 10 "$NAME" >/dev/null 2>&1 || true' EXIT
    docker run -d --rm --platform linux/amd64 --name "$NAME" \
      -e MOSAIC_AGENT_CLOUD_TOKEN="$TOKEN" -e P5_VNC_PASSWORD="$PASS" \
      -e P5_AGENT_ENTRY="$SERVER" -v "$OUT:/evidence" "$IMAGE" >/dev/null
    for i in {1..30}; do
      if docker exec "$NAME" curl -fs -H "Authorization: Bearer $TOKEN" http://localhost:8765/v1/health >/dev/null 2>&1; then break; fi
      sleep 1
    done
    printf '{"endpoint":"http://localhost:8765","desktop_url":"http://localhost:6080","token":"%s","vnc_password":"%s"}' "$TOKEN" "$PASS" \
      | docker exec -i "$NAME" /opt/lada/.venv/bin/python -c 'import sys; from pathlib import Path; p=Path("/tmp/connection.json"); p.write_text(sys.stdin.read()); p.chmod(0o600)'
    if docker exec "$NAME" /opt/lada/.venv/bin/python /opt/p5/run_p5_linux.py \
      "$MODE" --connection /tmp/connection.json --output /evidence/run --minutes 15; then
      echo '✓ Real local X11 GUI, actual RFB disconnect/reconnect, same task, download and cancellation'
      echo "PASS P5 Linux desktop $MODE (CUDA NOT RUN)"
    else
      docker logs "$NAME" > "$OUT/container.log" 2>&1
      echo 'FAIL P5 Linux offline desktop; see preserved evidence'; exit 1
    fi
    ;;
  --real) shift; exec python3 verify/run_p5_linux.py "$@" ;;
  *) echo 'FAIL P5 Linux: expected --build, --offline or --real'; exit 1 ;;
esac
