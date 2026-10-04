#!/usr/bin/env python3
"""Bounded P5 acceptance. Never starts, purchases, or switches cloud machines."""
import argparse
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
from datetime import datetime, timezone
import urllib.parse
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def values(payload):
    return dict(line.split("=", 1) for line in payload.decode().splitlines() if "=" in line)


class Acceptance:
    def __init__(self, args):
        connection = json.loads(args.connection.read_text())
        self.url = urllib.parse.urlsplit(connection["endpoint"])
        if self.url.scheme != "https" or not self.url.hostname or self.url.username or self.url.query:
            raise RuntimeError("HTTPS relay endpoint required")
        self.token = connection["token"]
        if datetime.fromisoformat(connection["expires_utc"].replace("Z", "+00:00")) <= datetime.now(timezone.utc):
            raise RuntimeError("deployment connection has expired; do not silently restart the cloud machine")
        available = (datetime.fromisoformat(connection["expires_utc"].replace("Z", "+00:00")) - datetime.now(timezone.utc)).total_seconds()
        self.deadline = time.monotonic() + min(args.minutes * 60, available)
        self.output = args.output
        self.output.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.jobs = []
        self.checks = []

    def request(self, method, path, body=None, reserve=False):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0 or (not reserve and remaining <= 45):
            raise RuntimeError("acceptance deadline reached; reserve remaining time for cancellation/shutdown")
        connection = http.client.HTTPSConnection(self.url.hostname, self.url.port or 443, timeout=10)
        try:
            connection.request(method, self.url.path.rstrip("/") + path, body,
                               {"Authorization": "Bearer " + self.token})
            response = connection.getresponse()
            payload = response.read()
            if response.status != 200:
                raise RuntimeError(f"agent HTTP {response.status}: {payload[:300].decode(errors='replace')}")
            return payload
        finally:
            connection.close()

    def action(self, action, job, session, method="GET", reserve=False):
        return self.request(method, f"/v1/jobs/{job}/{action}?session={session}", reserve=reserve)

    def open(self, job):
        reply = values(self.request("POST", f"/v1/jobs/{job}/session"))
        if reply.get("transport") != "agent-gui" or not reply.get("session_id"):
            raise RuntimeError("non-GUI transport or missing session")
        session = reply["session_id"]
        self.jobs.append((job, session))
        return session

    def passed(self, label):
        self.checks.append(label)
        print("✓ " + label, flush=True)

    def evidence(self, job, session, name, cancelled=False, reconnected=False):
        payload = self.action("evidence", job, session, reserve=True)
        (self.output / (name + ".zip")).write_bytes(payload)
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            required = ["desktop-ready.png", "action-start.png", "gpu.txt"]
            required += ["action-cancel.png"] if cancelled else []
            required += ["action-reconnect.png"] if reconnected else []
            for item in required:
                if len(archive.read(item)) < 8:
                    raise RuntimeError("empty evidence: " + item)
            if manifest.get("session_id") != session or manifest.get("gui_actions", 0) < 3:
                raise RuntimeError("invalid GUI session evidence")
            if cancelled and (not manifest.get("powershell_exited") or manifest.get("cancel_after") != []
                              or len(manifest.get("cancel_before", [])) < 2):
                raise RuntimeError("cancellation did not prove process exit")
            if reconnected and (not manifest.get("transport_drops") or not manifest.get("reconnect_processes")):
                raise RuntimeError("reconnect did not recover the live desktop process")
            return manifest

    def cleanup(self, job, session):
        reply = values(self.request("DELETE", f"/v1/jobs/{job}?session={session}", reserve=True))
        if reply.get("cleaned") != "true":
            raise RuntimeError("cleanup not acknowledged")
        self.jobs.remove((job, session))


def run(args):
    test = Acceptance(args)
    core = None
    try:
        primary_deadline = min(test.deadline - 45, time.monotonic() + 240)
        # Prepare once; the success chain always runs before optional cancellation.
        sample = test.output / "cancel-input.mp4"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
                        "testsrc2=size=640x360:rate=24", "-t", "60", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", str(sample)], check=True, timeout=30)
        # Completion traverses the actual Core provider and existing adapter, not SSH.
        source = test.output / "input.mp4"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(sample), "-t", "2", str(source)], check=True, timeout=20)
        profile_dir = test.output / "profiles"
        profile_dir.mkdir()
        (profile_dir / "p5.conf").write_text(f"endpoint={self_endpoint(test)}\ntoken_env=MOSAIC_P5_TOKEN\ntimeout_seconds=10\n")
        config = test.output / "agent-cloud.conf"
        config.write_text(f"version=1\nadapter={ROOT / 'verify/p5_success_adapter.py'}\nprofile=p5\npoll_millis=500\nstatus_retries=1\n")
        # Matches the existing Core v1 stable job identity without changing Core.
        digest = 0xcbf29ce484222325
        for byte in str(source).encode():
            digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
        digest ^= source.stat().st_size ^ source.stat().st_mtime_ns
        complete_job = f"mosaic-agent-{digest:016x}"
        complete_session = test.open(complete_job)
        env = dict(os.environ, MOSAIC_P5_TOKEN=test.token, MOSAIC_AGENT_CLOUD_HTTP_PROFILE_DIR=str(profile_dir),
                   MOSAIC_P5_EVIDENCE_DIR=str(test.output))
        with (test.output / "core.log").open("w") as log:
            core = subprocess.Popen([str(args.core), "--provider", "agent-cloud-computer", "--agent-cloud-config", str(config),
                                     "--input", str(source), "--output", str(test.output / "output.mp4")], env=env, stdout=log, stderr=log)
            while core.poll() is None:
                if time.monotonic() >= primary_deadline - 30:
                    raise RuntimeError("Core completion deadline reached")
                time.sleep(0.5)
            if core.returncode:
                raise RuntimeError("Core restore failed; inspect core.log")
        proof = test.evidence(complete_job, complete_session, "complete", reconnected=True)
        result = test.output / "output.mp4"
        if proof.get("output.mp4_sha256") != hashlib.sha256(result.read_bytes()).hexdigest():
            raise RuntimeError("downloaded result hash mismatch")
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(result)], capture_output=True, check=True, timeout=15)
        (test.output / "ffprobe.json").write_bytes(probe.stdout)
        if not any(stream.get("codec_type") == "video" for stream in json.loads(probe.stdout)["streams"]):
            raise RuntimeError("downloaded output has no video stream")
        test.jobs.remove((complete_job, complete_session))  # Core already cleaned up.
        test.passed("Core agent-cloud-computer completion, download hash and ffprobe")
        cancellation = "SKIP: not requested or less than 120 seconds remain"
        if args.cancel_if_time and test.deadline - time.monotonic() >= 120:
            try:
                job = "p5-cancel-" + uuid.uuid4().hex
                session = test.open(job)
                test.action("readiness", job, session)
                test.request("PUT", f"/v1/jobs/{job}/input?session={session}", sample.read_bytes())
                test.action("start", job, session, "POST")
                while True:
                    status = values(test.action("status", job, session))
                    proof = test.evidence(job, session, "cancel-launch")
                    if status.get("state") != "running":
                        raise RuntimeError("optional job ended before cancellation")
                    if len(proof.get("processes", [])) > 1:
                        break
                    if test.deadline - time.monotonic() < 60:
                        raise RuntimeError("optional cancellation time reserve reached")
                    time.sleep(0.5)
                test.action("cancel", job, session, "POST", reserve=True)
                test.evidence(job, session, "cancel", cancelled=True)
                test.cleanup(job, session)
                test.passed("Optional GUI cancellation and parent/child exit")
                cancellation = "PASS"
            except Exception as error:
                cancellation = "FAIL: " + str(error)
                (test.output / "report.json").write_text(json.dumps({"result": "FAIL", "primary_chain": "PASS", "cancellation": cancellation, "checks": test.checks, "fixture": False}, indent=2))
                raise
        (test.output / "report.json").write_text(json.dumps({"result": "PASS", "primary_chain": "PASS", "cancellation": cancellation, "checks": test.checks, "fixture": False}, indent=2))
        print("PASS P5 primary success chain; " + cancellation + " — Stop AirGPU now", flush=True)
    except BaseException:
        if core is not None and core.poll() is None:
            core.terminate()
            try:
                core.wait(timeout=10)
            except subprocess.TimeoutExpired:
                core.kill()
        for job, session in list(test.jobs):
            try:
                test.action("cancel", job, session, "POST", reserve=True)
                test.evidence(job, session, "failure-" + job)
                test.cleanup(job, session)
            except Exception:
                pass  # Never claim cleanup/exit PASS if the relay is lost.
        if not (test.output / "report.json").exists():
            (test.output / "report.json").write_text(json.dumps({"result": "FAIL", "checks": test.checks, "fixture": False}))
        raise


def self_endpoint(test):
    return urllib.parse.urlunsplit(test.url)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--core", type=Path, default=ROOT / "core/target/debug/mosaic-core")
    parser.add_argument("--minutes", type=int, default=10, choices=range(2, 21))
    parser.add_argument("--cancel-if-time", action="store_true", help="Optional cancellation only after primary PASS and with >=120 seconds remaining")
    arguments = parser.parse_args()
    try:
        run(arguments)
    except BaseException as error:
        print(f"FAIL P5 real Agent Cloud Computer: {error}; STOP AND SHUT DOWN AirGPU", flush=True)
        raise SystemExit(1)
