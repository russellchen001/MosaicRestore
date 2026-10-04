#!/usr/bin/env python3
"""Success-first Linux desktop acceptance. Never deploys or starts cloud resources."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "mosaicrestore/p5-linux-desktop:20261004"


class Test:
    def __init__(self, args):
        self.args = args
        self.connection = json.loads(args.connection.read_text())
        password = self.connection.get("vnc_password", self.connection.get("password", ""))
        if len(password) != 8:
            raise ValueError("connection requires an 8-character vnc_password")
        if "password" in self.connection and self.connection["password"] != password:
            raise ValueError("conflicting password and vnc_password")
        self.connection["vnc_password"] = password
        self.output = args.output.resolve()
        self.output.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.deadline = time.monotonic() + args.minutes * 60
        self.jobs = []
        self.events = []
        self.core = None
        self.primary = False
        self.cancelled = False
        self.viewer = None
        if not args.offline and not args.local_cpu:
            for key in ("endpoint", "desktop_url"):
                if not self.connection[key].startswith("https://"):
                    raise RuntimeError("real acceptance requires authenticated HTTPS services")
            expiry = datetime.fromisoformat(self.connection["expires_utc"].replace("Z", "+00:00"))
            if expiry <= datetime.now(timezone.utc):
                raise RuntimeError("expired acceptance window")
            self.deadline = min(self.deadline, time.monotonic() + (expiry - datetime.now(timezone.utc)).total_seconds())

    def request(self, action, job, session="", method="GET", body=None):
        if time.monotonic() >= self.deadline:
            raise RuntimeError("acceptance time limit; STOP RunPod")
        path = f"/v1/jobs/{job}" + ("/" + action if action else "")
        if session:
            path += "?session=" + session
        req = urllib.request.Request(self.connection["endpoint"].rstrip("/") + path, body,
                                     {"Authorization": "Bearer " + self.connection["token"],
                                      "User-Agent": "MosaicRestore-P5/1.0"}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60 if action == "input" else 10) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace").strip()
            raise RuntimeError(f"{action or method} HTTP {error.code}: {detail}") from error
        self.events.append({"action": action, "job": job, "at": time.time()})
        return data

    def status(self, job, session):
        result = dict(line.split("=", 1) for line in self.request("status", job, session).decode().splitlines())
        self.events[-1]["status"] = result
        return result

    def open(self, job):
        data = dict(line.split("=", 1) for line in self.request("session", job, method="POST").decode().splitlines())
        if data.get("transport") != "agent-gui":
            raise RuntimeError("non-GUI provider")
        session = data["session_id"]
        self.jobs.append((job, session))
        return session

    def evidence(self, job, session, name):
        data = self.request("evidence", job, session)
        (self.output / (name + ".zip")).write_bytes(data)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            for item in ("desktop-ready.png", "action-before.png", "action-start.png"):
                if not archive.read(item).startswith(b"\x89PNG\r\n\x1a\n"):
                    raise RuntimeError("invalid GUI PNG " + item)
            if manifest.get("session_id") != session or not manifest.get("window_id") or manifest.get("gui_actions", 0) < 3:
                raise RuntimeError("missing GUI action identity")
            if bool(manifest.get("fixture")) != self.args.offline:
                raise RuntimeError("fixture cannot pass real acceptance")
            return manifest

    def prepare_desktop(self, job, session):
        config = dict(self.connection, job=job, session=session, fixture=self.args.offline,
                      local_cpu=self.args.local_cpu, preconnect=True)
        if Path("/opt/p5/p5_desktop_reconnect.py").exists():
            command = [sys.executable, "/opt/p5/p5_desktop_reconnect.py", str(self.output)]
        else:
            command = ["docker", "run", "--rm", "-i", "--platform", "linux/amd64",
                       "-v", str(self.output) + ":/evidence", "-v",
                       str(ROOT / "verify/p5_desktop_reconnect.py") + ":/opt/p5/p5_desktop_reconnect.py:ro",
                       "--entrypoint", "/opt/lada/.venv/bin/python",
                       self.args.image, "/opt/p5/p5_desktop_reconnect.py", "/evidence"]
        self.viewer_log = (self.output / "desktop-helper.log").open("wb")
        self.viewer = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=self.viewer_log, stderr=self.viewer_log)
        self.viewer.stdin.write(json.dumps(config).encode())
        self.viewer.stdin.close()
        end = min(self.deadline, time.monotonic() + 30)
        while not (self.output / "viewer-ready").exists():
            if self.viewer.poll() is not None or time.monotonic() >= end:
                raise RuntimeError("desktop viewer not ready before GUI task launch; see desktop-helper.log")
            time.sleep(0.1)

    def desktop_reconnect(self, job, session):
        (self.output / "allow-reconnect").write_text("actual task is running")
        if self.viewer.wait(timeout=80):
            raise RuntimeError("desktop reconnect failed; see desktop-helper.log")
        proof = self.evidence(job, session, "reconnect")
        if not proof.get("same_task_verified") or not proof.get("reconnect_processes") or not proof.get("transport_drops"):
            raise RuntimeError("live task continuity was not proven")

    def wait_running(self, job, session):
        end = min(self.deadline, time.monotonic() + 60)
        while time.monotonic() < end:
            status = self.status(job, session)
            if status["state"] == "failed":
                raise RuntimeError("GUI task failed: " + status.get("message", ""))
            if status["state"] == "succeeded":
                raise RuntimeError("task finished before required live reconnect")
            if status["state"] == "running":
                proof = self.evidence(job, session, "launch")
                if len(proof.get("processes", [])) >= 3:
                    return
            time.sleep(0.2)
        raise RuntimeError("task not running by launch deadline")

    def run(self):
        source = self.output / "input.mp4"
        if getattr(self.args, "input", None):
            shutil.copyfile(self.args.input, source)
        elif self.args.offline or self.args.local_cpu:
            source.write_bytes(Path("/opt/p5/fixtures/local-cpu.mp4" if self.args.local_cpu else
                                   "/opt/p5/fixtures/input.mp4").read_bytes())
        else:
            with source.open("wb") as handle:
                subprocess.run(["docker", "run", "--rm", "--platform", "linux/amd64", "--entrypoint", "cat",
                                self.args.image, "/opt/p5/fixtures/input.mp4"], stdout=handle, check=True, timeout=30)
        if getattr(self.args, "cancel_only", False):
            prior = self.args.primary_evidence.resolve()
            report = json.loads((prior / "report.json").read_text())
            if not report.get("primary_chain") or report.get("fixture") or report.get("local_cpu"):
                raise RuntimeError("cancel-only requires authoritative real primary acceptance")
            with zipfile.ZipFile(prior / "complete.zip") as archive:
                manifest = json.loads(archive.read("manifest.json"))
            if hashlib.sha256((prior / "output.mp4").read_bytes()).hexdigest() != manifest.get("output.mp4_sha256"):
                raise RuntimeError("authoritative output hash mismatch")
            with zipfile.ZipFile(prior / "reconnect.zip") as archive:
                if not json.loads(archive.read("manifest.json")).get("same_task_verified"):
                    raise RuntimeError("authoritative live reconnect evidence missing")
            self.primary = True
            self.cancel(source)
            return
        if self.args.offline or self.args.local_cpu:
            job = "p5-linux-" + uuid.uuid4().hex
        else:
            digest = 0xcbf29ce484222325
            for byte in str(source).encode():
                digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
            digest ^= source.stat().st_size ^ source.stat().st_mtime_ns
            job = f"mosaic-agent-{digest:016x}"
        session = self.open(job)
        self.prepare_desktop(job, session)
        if self.args.offline or self.args.local_cpu:
            self.request("readiness", job, session)
            self.request("input", job, session, "PUT", source.read_bytes())
            self.request("start", job, session, "POST")
        else:
            profiles = self.output / "profiles"
            profiles.mkdir()
            (profiles / "p5.conf").write_text("endpoint=" + self.connection["endpoint"] +
                "\ntoken_env=MOSAIC_P5_TOKEN\ntimeout_seconds=10\nruntime=linux-x11-pyautogui\n")
            config = self.output / "agent-cloud.conf"
            config.write_text(f"version=1\nadapter={ROOT / 'adapters/http_agent_cloud_controller.py'}\nprofile=p5\npoll_millis=500\nstatus_retries=1\n")
            self.log = (self.output / "core.log").open("w")
            self.core = subprocess.Popen([str(self.args.core), "--provider", "agent-cloud-computer", "--agent-cloud-config",
                str(config), "--input", str(source), "--output", str(self.output / "output.mp4")],
                env=dict(os.environ, MOSAIC_P5_TOKEN=self.connection["token"], MOSAIC_AGENT_CLOUD_HTTP_PROFILE_DIR=str(profiles)),
                stdout=self.log, stderr=self.log)
        self.wait_running(job, session)
        self.desktop_reconnect(job, session)
        while True:
            if self.core is not None:
                if self.core.poll() is not None:
                    if self.core.returncode:
                        raise RuntimeError("Core failed; see core.log")
                    break
            else:
                status = self.status(job, session)
                if status["state"] == "succeeded":
                    (self.output / "output.mp4").write_bytes(self.request("output", job, session))
                    break
                if status["state"] == "failed":
                    raise RuntimeError("restore failed")
            if time.monotonic() > self.deadline - 120:
                raise RuntimeError("primary chain exceeded reserve; STOP RunPod")
            time.sleep(0.5)
        manifest = self.evidence(job, session, "complete")
        result = self.output / "output.mp4"
        digest = hashlib.sha256(result.read_bytes()).hexdigest()
        if manifest.get("output.mp4_sha256") != digest:
            raise RuntimeError("output hash mismatch")
        (self.output / "SHA256SUMS").write_text(digest + "  output.mp4\n" + hashlib.sha256(source.read_bytes()).hexdigest() + "  input.mp4\n")
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(result)],
                               capture_output=True, check=True, timeout=15)
        if not any(s["codec_type"] == "video" for s in json.loads(probe.stdout)["streams"]):
            raise RuntimeError("no video stream")
        (self.output / "ffprobe.json").write_bytes(probe.stdout)
        self.primary = True
        if self.args.offline or self.args.local_cpu:
            self.request("", job, session, "DELETE")
        self.jobs.remove((job, session))
        self.cancel(source)

    def cancel(self, source):
        if self.deadline - time.monotonic() < 120:
            raise RuntimeError("primary PASS, but full cancellation acceptance not run")
        job = "p5-cancel-" + uuid.uuid4().hex
        session = self.open(job)
        self.request("readiness", job, session)
        self.request("input", job, session, "PUT", source.read_bytes())
        self.request("start", job, session, "POST")
        self.wait_running(job, session)
        self.request("cancel", job, session, "POST")
        manifest = self.evidence(job, session, "cancel")
        if not manifest.get("task_exited") or not manifest.get("terminal_exited") or manifest.get("cancel_after") != [] or len(manifest.get("cancel_before", [])) < 2:
            raise RuntimeError("cancellation exit not proven")
        self.request("", job, session, "DELETE")
        self.jobs.remove((job, session))
        self.cancelled = True

    def report(self, error=None):
        (self.output / "report.json").write_text(json.dumps({"fixture": self.args.offline, "local_cpu": self.args.local_cpu, "primary_chain": self.primary,
            "cancellation": self.cancelled, "result": "FAIL" if error else "PASS", "error": error,
            "events": self.events, "cancel_only": bool(getattr(self.args, "cancel_only", False)),
            "primary_evidence": str(getattr(self.args, "primary_evidence", None)),
            "platform_stop": "NOT VERIFIED by runner; collect console evidence"}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection", required=True, type=Path)
    parser.add_argument("--input", type=Path, help="External acceptance video; does not change the fixed runtime image")
    parser.add_argument("--cancel-only", action="store_true", help="Reuse real primary evidence; run cancellation only")
    parser.add_argument("--primary-evidence", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--local-cpu", action="store_true", help="Actual local Lada CPU GUI execution; not CUDA/cloud acceptance")
    parser.add_argument("--minutes", type=int, default=20, choices=range(3, 26))
    parser.add_argument("--core", type=Path, default=ROOT / "core/target/debug/mosaic-core")
    parser.add_argument("--image", default=IMAGE)
    args = parser.parse_args()
    if args.cancel_only and (not args.primary_evidence or not args.input):
        parser.error("cancel-only requires --primary-evidence and --input")
    test = Test(args)
    try:
        test.run()
        test.report()
        print("PASS P5 Linux " + ("offline GUI fixture (CUDA NOT RUN)" if args.offline else
              "real local Lada CPU desktop (CUDA NOT RUN)" if args.local_cpu else "primary+cancel; collect RunPod stopped/billing proof"))
    except BaseException as error:
        if test.viewer is not None and test.viewer.poll() is None:
            test.viewer.terminate()
        if test.core is not None and test.core.poll() is None:
            test.core.terminate()
        for job, session in test.jobs:
            try:
                test.evidence(job, session, "failure")
                test.request("cancel", job, session, "POST")
            except Exception:
                pass
        test.report(str(error))
        print("FAIL P5 Linux: " + str(error) + "; STOP RunPod immediately")
        raise SystemExit(1)
