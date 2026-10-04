#!/bin/bash
set -euo pipefail
: "${MOSAIC_AGENT_CLOUD_TOKEN:?agent token required}"
: "${P5_VNC_PASSWORD:?VNC password required}"
test ${#P5_VNC_PASSWORD} -eq 8 || { echo 'FAIL VNC password must be 8 random characters'; exit 1; }
mkdir -p /root/.vnc /workspace/p5
rm -f /workspace/p5/desktop-ready.json
chmod 700 /root/.vnc /workspace/p5
printf '%s\n' "$P5_VNC_PASSWORD" | tigervncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
tigervncserver :1 -geometry 1280x800 -depth 24 -localhost yes \
  -SecurityTypes VncAuth -rfbauth /root/.vnc/passwd -xstartup /opt/p5/start-xfce.sh
export DISPLAY=:1
export XAUTHORITY=/root/.Xauthority
websockify --web=/usr/share/novnc 0.0.0.0:6080 127.0.0.1:5901 > /workspace/p5/novnc.log 2>&1 &
relay=$!
trap 'kill "$relay" 2>/dev/null || true; tigervncserver -kill :1 >/dev/null 2>&1 || true' EXIT
deadline=$((SECONDS + 60))
until /opt/lada/.venv/bin/python /opt/p5/p5_desktop_probe.py --local --output /workspace/p5 \
    > /workspace/p5/desktop-probe.log 2>&1; do
  if (( SECONDS >= deadline )) || ! kill -0 "$relay" 2>/dev/null; then
    echo 'FAIL desktop readiness: VNC/Xfce/WebSocket/RFB handshake not ready'
    cat /workspace/p5/desktop-probe.log
    exit 1
  fi
  sleep 1
done
echo 'PASS desktop readiness: authenticated RFB framebuffer and Xfce session'
/opt/lada/.venv/bin/python "${P5_AGENT_ENTRY:-/opt/p5/linux_gui_agent.py}" --config /opt/p5/agent.json &
agent=$!
trap 'kill "$agent" "$relay" 2>/dev/null || true; tigervncserver -kill :1 >/dev/null 2>&1 || true' EXIT
trap 'exit 143' TERM INT
wait "$agent"
