"""Fault injection into a real local running task; not kernel PID reuse claim."""
import json
from pathlib import Path
import subprocess
import urllib.error
import urllib.request


def verify(config, output):
    path = Path("/workspace/p5/jobs") / config["job"] / "session.json"
    original = json.loads(path.read_text())
    active = subprocess.check_output(["xdotool", "getactivewindow"], text=True).strip()
    checks = []
    def rejected(action, session, code):
        request = urllib.request.Request(config["endpoint"] + f"/v1/jobs/{config['job']}/{action}?session={session}",
                    headers={"Authorization": "Bearer " + config["token"],
                             "User-Agent": "MosaicRestore-P5/1.0"}, method="POST")
        try:
            urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            if error.code != code:
                raise RuntimeError("wrong rejection code") from error
        else:
            raise RuntimeError("unsafe reconnect was accepted")
    try:
        rejected("desktop-checkpoint", "wrong-session", 403)
        if subprocess.check_output(["xdotool", "getactivewindow"], text=True).strip() != active:
            raise RuntimeError("wrong session changed desktop focus")
        checks.append("wrong session rejected without GUI mutation")
        altered = json.loads(json.dumps(original))
        altered["transport_drops"] = 1
        altered["desktop_checkpoint"]["restoration_task"]["StartTicks"] = "-1"
        path.write_text(json.dumps(altered))
        rejected("reconnect", config["session"], 500)
        checks.append("persisted PID start-time mismatch rejected against actual /proc identity")
        altered = json.loads(json.dumps(original))
        altered["transport_drops"] = 1
        altered["desktop_checkpoint"]["status"]["progress"] = 101
        path.write_text(json.dumps(altered))
        rejected("reconnect", config["session"], 500)
        checks.append("progress below recorded checkpoint rejected during live task")
    finally:
        path.write_text(json.dumps(original))
    (output / "live-runtime-guards.json").write_text(json.dumps({"checks": checks,
        "fault_injection": True, "kernel_pid_reuse": "NOT FORCED", "restoration_fixture": False}, indent=2))
