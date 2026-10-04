#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${MOSAIC_P5_IMAGE:-mosaicrestore/p5-linux-desktop:20261004-rfb1}
OUT=${1:?absolute evidence directory required}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
NAME=mosaic-p5-rfb-$$
TOKEN=$(openssl rand -hex 32)
PASSWORD=$(openssl rand -hex 4)
trap 'docker stop -t 5 "$NAME" >/dev/null 2>&1 || true' EXIT
for round in 1 2 3; do
  docker run -d --rm --platform linux/amd64 --name "$NAME" \
    -e MOSAIC_AGENT_CLOUD_TOKEN="$TOKEN" -e P5_VNC_PASSWORD="$PASSWORD" \
    -p 127.0.0.1:16080:6080 -v "$OUT:/evidence" "$IMAGE" >/dev/null
  ready=false
  for tick in {1..60}; do
    if docker exec "$NAME" test -f /workspace/p5/desktop-ready.json; then ready=true; break; fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    docker logs "$NAME" > "$OUT/start-failure.log" 2>&1
    echo 'FAIL P5 RFB startup readiness'; exit 1
  fi
  docker exec "$NAME" /opt/lada/.venv/bin/python /opt/p5/p5_desktop_probe.py \
    --local --output "/evidence/cold-$round" > "$OUT/cold-$round.log"
  echo "✓ Cold start $round: VNC + Xauthority/Xfce + authenticated WebSocket/RFB framebuffer"
  if [ "$round" != 3 ]; then docker stop -t 5 "$NAME" >/dev/null; fi
done
# Independent browser container traverses Docker-published HTTP/WebSocket ports.
docker run --rm --platform linux/amd64 -e P5_VNC_PASSWORD="$PASSWORD" \
  -v "$OUT:/evidence" --entrypoint /opt/lada/.venv/bin/python "$IMAGE" \
  /opt/p5/p5_desktop_probe.py --url http://host.docker.internal:16080 \
  --output /evidence/external > "$OUT/external.log"
echo '✓ Independent client: published port → noVNC → WebSocket → RFB → visible Xfce'
if docker exec -e P5_VNC_PASSWORD=wrong123 "$NAME" /opt/lada/.venv/bin/python \
  /opt/p5/p5_desktop_probe.py --local > "$OUT/wrong-password.log" 2>&1; then
  echo 'FAIL P5 RFB accepted wrong password'; exit 1
fi
echo '✓ Wrong password rejected'
if docker exec -e XAUTHORITY=/tmp/nonexistent-authority "$NAME" /opt/lada/.venv/bin/python \
  /opt/p5/p5_desktop_probe.py --local > "$OUT/wrong-xauthority.log" 2>&1; then
  echo 'FAIL P5 RFB accepted missing Xauthority'; exit 1
fi
echo '✓ Invalid Xauthority rejected'
if docker exec -e DISPLAY=:99 "$NAME" /opt/lada/.venv/bin/python \
  /opt/p5/p5_desktop_probe.py --local > "$OUT/wrong-display.log" 2>&1; then
  echo 'FAIL P5 RFB accepted unavailable X session'; exit 1
fi
echo '✓ Unavailable DISPLAY rejected'
docker exec "$NAME" bash -c 'cat /proc/net/tcp /proc/net/tcp6; pgrep -a Xtigervnc; pgrep -a websockify; pgrep -a xfce4-session' \
  > "$OUT/listeners.txt"
docker exec "$NAME" pkill -f /usr/bin/websockify
if docker exec "$NAME" /opt/lada/.venv/bin/python /opt/p5/p5_desktop_probe.py --local \
  > "$OUT/dead-relay.log" 2>&1; then
  echo 'FAIL P5 RFB accepted dead relay'; exit 1
fi
echo '✓ Lost WebSocket relay fails readiness'
if docker exec "$NAME" curl -fs -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8765/v1/health > "$OUT/dead-relay-health.txt" 2>&1; then
  echo 'FAIL P5 RFB agent advertised readiness after relay loss'; exit 1
fi
echo '✓ Agent health fails closed after transport loss'
docker exec "$NAME" pkill -x Xtigervnc
if docker exec "$NAME" /opt/lada/.venv/bin/python /opt/p5/p5_desktop_probe.py --local \
  > "$OUT/dead-vnc.log" 2>&1; then
  echo 'FAIL P5 RFB accepted closed VNC socket'; exit 1
fi
echo '✓ Closed VNC socket fails readiness'
echo 'PASS P5 RFB desktop transport (CUDA NOT RUN)'
