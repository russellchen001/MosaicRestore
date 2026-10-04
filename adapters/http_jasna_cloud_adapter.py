#!/usr/bin/env python3
"""Cloud/NVIDIA adapter for a pinned Jasna runtime behind the existing HTTPS relay."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from http_agent_cloud_controller import Relay, fail, parse_cli, print_response, read_profile


def required(values: dict[str, str], key: str) -> str:
    value = values.get(key, "")
    if not value:
        fail("invalid-request", f"missing --{key}", 2)
    return value


def session_root() -> Path:
    root = Path(os.environ.get(
        "MOSAIC_JASNA_SESSION_DIR",
        Path.home() / ".config/mosaicrestore/jasna-cloud-sessions",
    ))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return root


def session_path(job: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", job):
        fail("invalid-request", "invalid job", 2)
    return session_root() / f"{job}.session"


def load_session(job: str) -> str:
    try:
        value = session_path(job).read_text(encoding="utf-8").strip()
    except OSError as error:
        fail("provider-unavailable", f"Jasna cloud session is unavailable: {error}", 3)
    if not value:
        fail("provider-unavailable", "Jasna cloud session is empty", 3)
    return value


def save_session(job: str, value: str) -> None:
    path = session_path(job)
    path.write_text(value + "\n", encoding="utf-8")
    path.chmod(0o600)


def response_values(payload: bytes) -> dict[str, str]:
    values = {}
    for line in payload.decode("utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def main() -> None:
    action, args = parse_cli(sys.argv[1:])
    profile_name = required(args, "profile")
    relay = Relay(read_profile(profile_name))
    job = args.get("job", "")

    if action == "validate":
        relay.request("GET", "/v1/health")
        print("contract_version=1\ntransport=cloud-relay\nruntime=jasna-0.10.0")
        return
    required(args, "job")
    if action == "upload":
        source = Path(required(args, "input"))
        if not source.is_file():
            fail("invalid-request", "upload input is missing", 2)
        opened = response_values(relay.request("POST", f"/v1/jobs/{job}/session"))
        session = opened.get("session_id", "")
        if not session:
            fail("provider-unavailable", "relay returned no session", 3)
        save_session(job, session)
        relay.upload(f"/v1/jobs/{job}/input?session={session}", source)
        return

    session = load_session(job)
    suffix = f"session={session}&mode=headless"
    if action == "readiness":
        print_response(relay.request("GET", f"/v1/jobs/{job}/readiness?{suffix}"))
    elif action == "estimate":
        print_response(relay.request("GET", f"/v1/jobs/{job}/estimate?session={session}"))
    elif action == "start":
        print_response(relay.request("POST", f"/v1/jobs/{job}/start?{suffix}"))
    elif action == "status":
        print_response(relay.request("GET", f"/v1/jobs/{job}/status?session={session}"))
    elif action == "cancel":
        print_response(relay.request("POST", f"/v1/jobs/{job}/cancel?{suffix}"))
    elif action == "download":
        relay.download(f"/v1/jobs/{job}/output?session={session}", Path(required(args, "output")))
    elif action == "evidence":
        relay.download(f"/v1/jobs/{job}/evidence?session={session}", Path(required(args, "output")))
    else:
        fail("invalid-request", f"unknown action: {action}", 2)


if __name__ == "__main__":
    main()
