#!/usr/bin/env python3
"""Acceptance-only download gate; forwards the unchanged production HTTP adapter."""
import http.client
import io
import json
import os
from pathlib import Path
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "adapters"))
import http_agent_cloud_controller as controller


def before_download(relay, job, session, output):
    path = f"/v1/jobs/{job}"
    query = "?session=" + session
    status = dict(line.split("=", 1) for line in relay.request("GET", path + "/status" + query).decode().splitlines() if "=" in line)
    if status.get("state") != "succeeded" or status.get("session_id") != session:
        raise RuntimeError("restoration must succeed before reconnect/download")
    connection = relay.connection()
    dropped = False
    try:
        connection.request("POST", relay.prefix + path + "/disconnect" + query,
                           headers={"Authorization": "Bearer " + relay.profile["token"]})
        reply = connection.getresponse()
        reply.read()
        dropped = reply.status >= 500  # A relay may translate the origin reset to 502.
    except (OSError, http.client.HTTPException):
        dropped = True
    finally:
        connection.close()
    if not dropped:
        raise RuntimeError("expected authenticated connection reset was not observed")
    reconnect = dict(line.split("=", 1) for line in relay.request("POST", path + "/reconnect" + query).decode().splitlines() if "=" in line)
    if reconnect.get("session_id") != session or reconnect.get("agent") != "ready":
        raise RuntimeError("reconnect changed or lost the session")
    evidence = relay.request("GET", path + "/evidence" + query)
    with zipfile.ZipFile(io.BytesIO(evidence)) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        if (manifest.get("session_id") != session or not manifest.get("transport_drops")
                or not manifest.get("reconnect_processes") or not manifest.get("action_receipt")):
            raise RuntimeError("missing same-desktop reconnect/GUI evidence")
        for name in ("desktop-ready.png", "action-start.png", "action-reconnect.png"):
            if not archive.read(name).startswith(b"\x89PNG\r\n\x1a\n"):
                raise RuntimeError("missing PNG GUI evidence: " + name)
    (output / "success-before-download.zip").write_bytes(evidence)
    (output / "success-session.json").write_text(json.dumps({"job": job, "session": session}))


if __name__ == "__main__":
    action, args = controller.parse_cli(sys.argv[1:])
    try:
        if action == "download":
            before_download(controller.Relay(controller.read_profile(args["profile"])),
                            args["job"], args["session"], Path(os.environ["MOSAIC_P5_EVIDENCE_DIR"]))
        controller.main()
    except Exception as error:
        controller.fail("execution-failed", "P5 success-first gate: " + str(error))
