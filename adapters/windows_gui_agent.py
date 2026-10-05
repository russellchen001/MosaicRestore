#!/usr/bin/env python3
"""Authenticated Windows relay that starts restoration through visible GUI actions."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import uuid
import zipfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


JOB_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,128}")
PERCENT_PATTERN = re.compile(r"(?<!\d)(\d{1,3})%(?!\d)")


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
    required = ("root", "application_path", "command_template", "ffprobe_path", "token_env")
    missing = [key for key in required if not config.get(key)]
    if missing:
        raise ValueError(f"agent config is missing: {', '.join(missing)}")
    token = os.environ.get(config["token_env"], "")
    if not token:
        raise ValueError("agent token environment variable is missing")
    config["token"] = token
    config["root"] = str(Path(config["root"]).resolve())
    return config


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    temporary.replace(path)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def powershell_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class AgentState:
    def __init__(self, config: dict) -> None:
        self.config = config
        self.root = Path(config["root"])
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()

    def job_root(self, job: str) -> Path:
        if not JOB_PATTERN.fullmatch(job):
            raise ValueError("invalid job id")
        return self.root / job

    def metadata_path(self, job: str) -> Path:
        return self.job_root(job) / "session.json"

    def require_session(self, job: str, session: str) -> tuple[Path, dict]:
        root = self.job_root(job)
        metadata = read_json(self.metadata_path(job))
        if not root.is_dir() or not session or metadata.get("session_id") != session:
            raise PermissionError("agent session not found")
        return root, metadata

    def health(self) -> None:
        if not Path(self.config["application_path"]).is_file():
            raise RuntimeError("configured restoration application is missing")
        if not Path(self.config["ffprobe_path"]).is_file():
            raise RuntimeError("configured ffprobe is missing")

    def open_session(self, job: str) -> str:
        root = self.job_root(job)
        root.mkdir(parents=True, exist_ok=True)
        path = self.metadata_path(job)
        with self.lock:
            metadata = read_json(path)
            if metadata.get("session_id"):
                return metadata["session_id"]
            session = f"agent-{uuid.uuid4()}"
            atomic_json(
                path,
                {
                    "session_id": session,
                    "created_at": time.time(),
                    "state": "pending",
                    "gui_actions": 0,
                    "runtime": "windows-uia",
                },
            )
            return session

    def readiness(self, job: str, session: str) -> None:
        root, _ = self.require_session(job, session)
        self.health()
        if self.config.get("jasna_version"):
            self.headless_readiness(job, session)
        try:
            import PIL  # noqa: F401
            import pywinauto  # noqa: F401
            import win32clipboard  # noqa: F401

            probe = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except (ImportError, OSError, subprocess.SubprocessError) as error:
            raise RuntimeError(f"Windows UI agent readiness failed: {error}") from error
        if probe.returncode != 0 or not probe.stdout.strip():
            raise RuntimeError("NVIDIA GPU is unavailable")
        from pywinauto import Desktop
        from PIL import ImageGrab

        if not Desktop(backend="uia").windows():
            raise RuntimeError("interactive Windows desktop is unavailable")
        ImageGrab.grab().save(root / "desktop-ready.png")
        (root / "gpu.txt").write_text(probe.stdout, encoding="utf-8")
        metadata = read_json(self.metadata_path(job))
        metadata["runtime"] = "jasna-windows-uia"
        atomic_json(self.metadata_path(job), metadata)

    def headless_readiness(self, job: str, session: str) -> None:
        root, metadata = self.require_session(job, session)
        self.health()
        probe = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=15, check=False,
        )
        version = subprocess.run(
            [self.config["application_path"], "--version"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        expected = str(self.config.get("jasna_version", "0.10.0"))
        models = [Path(path) for path in self.config.get("jasna_models", [])]
        cache = Path(self.config.get("tensorrt_cache", ""))
        if probe.returncode or not probe.stdout.strip():
            raise RuntimeError("NVIDIA GPU is unavailable")
        if version.returncode or expected not in (version.stdout + version.stderr):
            raise RuntimeError(f"Jasna version must be {expected}")
        if not models or any(not path.is_file() for path in models):
            raise RuntimeError("pinned Jasna model files are unavailable")
        engines = list(cache.glob("*.engine")) if cache.is_dir() else []
        if not engines:
            raise RuntimeError("T4 TensorRT cache is unavailable; paid-window compilation is forbidden")
        metadata.update({"runtime": "jasna-headless", "jasna_version": expected,
                         "tensorrt_engines": [path.name for path in engines]})
        atomic_json(self.metadata_path(job), metadata)
        (root / "gpu.txt").write_text(probe.stdout, encoding="utf-8")

    def processes(self, process_id: int) -> list[dict]:
        """Read-only process inventory; never starts the restoration application."""
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "@(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name) | ConvertTo-Json -Compress"],
            capture_output=True, text=True, timeout=15, check=True,
        )
        inventory = json.loads(result.stdout)
        if isinstance(inventory, dict):
            inventory = [inventory]
        ids = {process_id}
        while True:
            children = {int(item["ProcessId"]) for item in inventory
                        if int(item["ParentProcessId"]) in ids}
            expanded = ids | children
            if expanded == ids:
                break
            ids = expanded
        return [item for item in inventory if int(item["ProcessId"]) in ids]

    def reconnect(self, job: str, session: str) -> None:
        root, metadata = self.require_session(job, session)
        self.health()
        from pywinauto import Application

        process_id = int(metadata.get("powershell_pid", 0))
        if process_id:
            window_pid = int(metadata.get("window_pid", process_id))
            window = Application(backend="uia").connect(process=window_pid).top_window()
            window.capture_as_image().save(root / "action-reconnect.png")
        metadata["reconnect_processes"] = self.processes(process_id) if process_id else []
        metadata["reconnected_at"] = time.time()
        atomic_json(self.metadata_path(job), metadata)

    def evidence(self, job: str, session: str) -> bytes:
        root, metadata = self.require_session(job, session)
        manifest = dict(metadata)
        manifest["processes"] = self.processes(int(metadata.get("powershell_pid", 0)))
        for name in ("input.mp4", "output.mp4"):
            path = root / name
            if path.is_file():
                with path.open("rb") as handle:
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
                manifest[name + "_sha256"] = digest.hexdigest()
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            for name in ("desktop-ready.png", "action-start.png", "action-reconnect.png",
                         "action-cancel.png", "gpu.txt", "run.log", "state.txt", "error.txt"):
                path = root / name
                if path.is_file():
                    archive.write(path, name)
        return buffer.getvalue()

    def evidence_path(self, job: str, session: str) -> Path:
        self.job_root(job)
        return self.root / ".evidence" / f"{job}-{hashlib.sha256(session.encode()).hexdigest()}.zip"

    def estimate(self, job: str, session: str) -> tuple[str, str]:
        root, _ = self.require_session(job, session)
        input_path = root / "input.mp4"
        if not input_path.is_file():
            raise FileNotFoundError("uploaded input is missing")
        probe = subprocess.run(
            [
                self.config["ffprobe_path"],
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=nw=1:nk=1",
                str(input_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if probe.returncode != 0:
            raise RuntimeError("ffprobe could not read uploaded input")
        duration = float(probe.stdout.strip())
        seconds = duration * float(self.config.get("realtime_factor", 1.0))
        hourly = self.config.get("hourly_cost_usd")
        cost = "unknown" if hourly is None else f"{seconds * float(hourly) / 3600:.4f}"
        return f"{seconds:.1f}", cost

    def build_script(self, root: Path) -> Path:
        input_path = root / "input.mp4"
        output_path = root / "output.mp4"
        run_log = root / "run.log"
        state_path = root / "state.txt"
        error_path = root / "error.txt"
        command = self.config["command_template"].format(
            application=powershell_quote(str(Path(self.config["application_path"]))),
            input=powershell_quote(str(input_path)),
            output=powershell_quote(str(output_path)),
            job=powershell_quote(root.name),
        )
        script = root / "run-visible.ps1"
        script.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            f"Set-Content -LiteralPath {powershell_quote(str(state_path))} -Value 'running'\n"
            "try {\n"
            # Jasna logs INFO to stderr. Under 'Stop' the first such line became a
            # terminating error and a healthy run was recorded as failed, so the
            # native command runs non-terminating and is judged by its exit code.
            "  $ErrorActionPreference = 'Continue'\n"
            f"  & {{ {command} }} *>&1 | Tee-Object -FilePath {powershell_quote(str(run_log))}\n"
            "  $code = $LASTEXITCODE\n"
            "  $ErrorActionPreference = 'Stop'\n"
            "  if ($code -ne 0) { throw \"restoration exited $code\" }\n"
            f"  if (-not (Test-Path -LiteralPath {powershell_quote(str(output_path))})) {{ throw 'output missing' }}\n"
            f"  Set-Content -LiteralPath {powershell_quote(str(state_path))} -Value 'succeeded'\n"
            "} catch {\n"
            f"  $_ | Out-String | Set-Content -LiteralPath {powershell_quote(str(error_path))}\n"
            f"  Set-Content -LiteralPath {powershell_quote(str(state_path))} -Value 'failed'\n"
            "}\n",
            encoding="utf-8-sig",
        )
        return script

    def start(self, job: str, session: str) -> str:
        root, metadata = self.require_session(job, session)
        if not (root / "input.mp4").is_file():
            raise FileNotFoundError("uploaded input is missing")
        if metadata.get("state") == "running":
            return str(metadata.get("action_receipt", "existing-visible-session"))

        from pywinauto import Application, keyboard
        import win32clipboard

        script = self.build_script(root)
        # Windows 11 and Server 2025 hand a bare powershell.exe to Windows
        # Terminal, so the window belongs to another process and UIA finds none
        # for the one it started. conhost.exe forces the classic console, whose
        # window is owned by the launched process. PowerShell is its child.
        application = Application(backend="uia").start(
            "conhost.exe powershell.exe -NoLogo -NoExit -NoProfile", wait_for_idle=False
        )
        shell_pid = 0
        deadline = time.monotonic() + 15
        while not shell_pid and time.monotonic() < deadline:
            shell_pid = next((int(item["ProcessId"]) for item in self.processes(application.process)
                              if item["Name"].lower() == "powershell.exe"), 0)
            if not shell_pid:
                time.sleep(0.25)
        if not shell_pid:
            raise RuntimeError("conhost started but no PowerShell child appeared")
        window = application.top_window()
        window.wait("visible", timeout=20)
        window.set_focus()
        command = f"& {powershell_quote(str(script))}"
        win32clipboard.OpenClipboard()
        try:
            win32clipboard.EmptyClipboard()
            win32clipboard.SetClipboardText(command)
        finally:
            win32clipboard.CloseClipboard()
        keyboard.send_keys("^v{ENTER}", pause=0.05)
        screenshot = root / "action-start.png"
        window.capture_as_image().save(screenshot)
        receipt = f"uia-screenshot:{screenshot.name}"
        metadata.update(
            {
                "state": "running",
                "started_at": time.time(),
                "powershell_pid": shell_pid,
                "window_pid": application.process,
                "launch_processes": self.processes(shell_pid),
                "gui_actions": 3,
                "action_receipt": receipt,
            }
        )
        atomic_json(self.metadata_path(job), metadata)
        return receipt

    def start_headless(self, job: str, session: str) -> None:
        root, metadata = self.require_session(job, session)
        if not (root / "input.mp4").is_file():
            raise FileNotFoundError("uploaded input is missing")
        script = self.build_script(root)
        process = subprocess.Popen(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-File", str(script)],
            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
        )
        metadata.update({"state": "running", "started_at": time.time(),
                         "powershell_pid": process.pid, "runtime": "jasna-headless"})
        atomic_json(self.metadata_path(job), metadata)

    def status(self, job: str, session: str) -> dict:
        root, metadata = self.require_session(job, session)
        state_path = root / "state.txt"
        state = state_path.read_text(encoding="utf-8").strip() if state_path.is_file() else metadata.get("state", "pending")
        output = root / "output.mp4"
        if state == "succeeded" and not output.is_file():
            state = "failed"
        progress = 0
        log_path = root / "run.log"
        if log_path.is_file():
            raw = log_path.read_bytes()
            text = raw.decode("utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8", errors="replace")[-131072:]
            matches = [min(100, int(value)) for value in PERCENT_PATTERN.findall(text)]
            if matches:
                progress = matches[-1]
        if state == "succeeded":
            progress = 100
        message = ""
        error_path = root / "error.txt"
        if state == "failed" and error_path.is_file():
            message = error_path.read_text(encoding="utf-8", errors="replace").strip().replace("\n", " ")[:500]
        return {
            "state": state,
            "progress": progress,
            "gui_actions": int(metadata.get("gui_actions", 0)),
            "result_ready": output.is_file() and output.stat().st_size > 0,
            "message": message,
        }

    def cancel(self, job: str, session: str) -> None:
        root, metadata = self.require_session(job, session)
        process_id = int(metadata.get("powershell_pid", 0))
        if process_id:
            from pywinauto import Application, keyboard

            application = Application(backend="uia").connect(process=int(metadata.get("window_pid", process_id)))
            window = application.top_window()
            before = self.processes(process_id)
            tracked = {int(item["ProcessId"]) for item in before if int(item["ProcessId"]) != process_id}
            window.set_focus()
            keyboard.send_keys("^c", pause=0.05)
            window.capture_as_image().save(root / "action-cancel.png")
            metadata["gui_actions"] = int(metadata.get("gui_actions", 0)) + 2
            deadline = time.monotonic() + 10
            while True:
                after = self.processes(process_id)
                if not any(int(item["ProcessId"]) != process_id for item in after):
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("GUI cancellation did not stop restoration children")
                time.sleep(0.25)
            window.close()
            application.wait_for_process_exit(timeout=10)
            # Track the original children too: reparenting must not hide a survivor.
            survivors = [item for pid in tracked for item in self.processes(pid)
                         if int(item["ProcessId"]) == pid]
            if survivors:
                raise RuntimeError("restoration child survived GUI cancellation")
            metadata["cancel_before"] = before
            metadata["cancel_after"] = survivors
            metadata["powershell_exited"] = True
        metadata["state"] = "cancelled"
        metadata["cancelled_at"] = time.time()
        atomic_json(self.metadata_path(job), metadata)
        (root / "state.txt").write_text("cancelled", encoding="utf-8")

    def cancel_headless(self, job: str, session: str) -> None:
        root, metadata = self.require_session(job, session)
        process_id = int(metadata.get("powershell_pid", 0))
        before = self.processes(process_id) if process_id else []
        if process_id:
            subprocess.run(["taskkill.exe", "/PID", str(process_id), "/T", "/F"],
                           capture_output=True, timeout=15, check=False)
        survivors = self.processes(process_id) if process_id else []
        if survivors:
            raise RuntimeError("headless cancellation left surviving processes")
        metadata.update({"state": "cancelled", "cancelled_at": time.time(),
                         "cancel_before": before, "cancel_after": survivors})
        atomic_json(self.metadata_path(job), metadata)
        (root / "state.txt").write_text("cancelled", encoding="utf-8")

    def metadata(self, job: str, session: str) -> dict:
        _, metadata = self.require_session(job, session)
        started = float(metadata.get("started_at", metadata.get("created_at", time.time())))
        elapsed = max(0.0, time.time() - started)
        hourly = self.config.get("hourly_cost_usd")
        cost = "unknown" if hourly is None else f"{elapsed * float(hourly) / 3600:.4f}"
        return {
            "runtime": metadata.get("runtime", "windows-uia"),
            "elapsed_seconds": f"{elapsed:.1f}",
            "billed_cost_usd": cost,
        }


class Handler(BaseHTTPRequestHandler):
    server: "AgentServer"

    def log_message(self, fmt: str, *args) -> None:
        print(f"agent-relay {self.address_string()} {fmt % args}")

    def authorized(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {self.server.state.config['token']}"

    def text(self, status: int, body: str = "") -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def route(self) -> tuple[list[str], dict[str, list[str]]]:
        parsed = urlsplit(self.path)
        return [part for part in parsed.path.split("/") if part], parse_qs(parsed.query)

    def require_auth(self) -> bool:
        if self.authorized():
            return True
        self.text(HTTPStatus.UNAUTHORIZED, "unauthorized")
        return False

    def session(self, query: dict[str, list[str]]) -> str:
        return query.get("session", [""])[0]

    def do_GET(self) -> None:
        if not self.require_auth():
            return
        parts, query = self.route()
        try:
            if parts == ["v1", "health"]:
                self.server.state.health()
                self.text(HTTPStatus.OK, "status=ready\n")
                return
            if len(parts) != 4 or parts[:2] != ["v1", "jobs"]:
                self.text(HTTPStatus.NOT_FOUND, "not found")
                return
            job, action = parts[2], parts[3]
            session = self.session(query)
            if action == "readiness":
                headless = query.get("mode", [""])[0] == "headless"
                if headless:
                    self.server.state.headless_readiness(job, session)
                else:
                    self.server.state.readiness(job, session)
                self.text(
                    HTTPStatus.OK,
                    f"session_id={session}\ntransport={'cloud-relay' if headless else 'agent-gui'}\n"
                    "agent=ready\ndesktop=ready\ngpu=ready\ndriver=ready\ncuda=ready\n"
                    "runtime=ready\ndetector=ready\ncache_hit=true\napplication=ready\n",
                )
            elif action == "estimate":
                seconds, cost = self.server.state.estimate(job, session)
                self.text(HTTPStatus.OK, f"estimated_seconds={seconds}\nestimated_cost_usd={cost}\n")
            elif action == "status":
                status = self.server.state.status(job, session)
                body = (
                    f"session_id={session}\ntransport=agent-gui\nstate={status['state']}\n"
                    f"progress={status['progress']}\ngui_actions={status['gui_actions']}\n"
                    f"result_ready={str(status['result_ready']).lower()}\nmessage={status['message']}\n"
                )
                self.text(HTTPStatus.OK, body)
            elif action == "output":
                root, _ = self.server.state.require_session(job, session)
                output = root / "output.mp4"
                if not output.is_file() or output.stat().st_size == 0:
                    self.text(HTTPStatus.NOT_FOUND, "result is unavailable")
                    return
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(output.stat().st_size))
                self.end_headers()
                with output.open("rb") as handle:
                    shutil.copyfileobj(handle, self.wfile, length=1024 * 1024)
            elif action == "metadata":
                metadata = self.server.state.metadata(job, session)
                self.text(
                    HTTPStatus.OK,
                    "".join(f"{key}={value}\n" for key, value in metadata.items()),
                )
            elif action == "evidence":
                saved = self.server.state.evidence_path(job, session)
                payload = saved.read_bytes() if saved.is_file() else self.server.state.evidence(job, session)
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/zip")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.text(HTTPStatus.NOT_FOUND, "not found")
        except PermissionError as error:
            self.text(HTTPStatus.FORBIDDEN, str(error))
        except FileNotFoundError as error:
            self.text(HTTPStatus.NOT_FOUND, str(error))
        except (OSError, RuntimeError, ValueError) as error:
            self.text(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))

    def do_PUT(self) -> None:
        if not self.require_auth():
            return
        parts, query = self.route()
        if len(parts) != 4 or parts[:2] != ["v1", "jobs"] or parts[3] != "input":
            self.text(HTTPStatus.NOT_FOUND, "not found")
            return
        try:
            root, _ = self.server.state.require_session(parts[2], self.session(query))
            length = int(self.headers.get("Content-Length", "0"))
            maximum = int(self.server.state.config.get("max_upload_bytes", 500 * 1024**3))
            if length <= 0 or length > maximum:
                raise ValueError("invalid upload size")
            temporary = root / ".input.upload"
            remaining = length
            with temporary.open("wb") as handle:
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise OSError("upload ended early")
                    handle.write(chunk)
                    remaining -= len(chunk)
            temporary.replace(root / "input.mp4")
            self.text(HTTPStatus.OK, "uploaded=true\n")
        except PermissionError as error:
            self.text(HTTPStatus.FORBIDDEN, str(error))
        except (OSError, RuntimeError, ValueError) as error:
            self.text(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))

    def do_POST(self) -> None:
        if not self.require_auth():
            return
        parts, query = self.route()
        try:
            if len(parts) != 4 or parts[:2] != ["v1", "jobs"]:
                self.text(HTTPStatus.NOT_FOUND, "not found")
                return
            job, action = parts[2], parts[3]
            if action == "session":
                session = self.server.state.open_session(job)
                self.text(HTTPStatus.OK, f"session_id={session}\ntransport=agent-gui\n")
            elif action == "start":
                session = self.session(query)
                if query.get("mode", [""])[0] == "headless":
                    self.server.state.start_headless(job, session)
                    self.text(HTTPStatus.OK, "state=running\ntransport=cloud-relay\n")
                else:
                    receipt = self.server.state.start(job, session)
                    self.text(
                        HTTPStatus.OK,
                        f"state=running\ntransport=agent-gui\naction_receipt={receipt}\n",
                    )
            elif action == "reconnect":
                session = self.session(query)
                self.server.state.reconnect(job, session)
                self.text(HTTPStatus.OK, f"session_id={session}\nagent=ready\n")
            elif action == "disconnect":
                root, metadata = self.server.state.require_session(job, self.session(query))
                metadata["transport_drops"] = int(metadata.get("transport_drops", 0)) + 1
                atomic_json(root / "session.json", metadata)
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
            elif action == "cancel":
                if query.get("mode", [""])[0] == "headless":
                    self.server.state.cancel_headless(job, self.session(query))
                else:
                    self.server.state.cancel(job, self.session(query))
                self.text(HTTPStatus.OK, "state=cancelled\n")
            else:
                self.text(HTTPStatus.NOT_FOUND, "not found")
        except PermissionError as error:
            self.text(HTTPStatus.FORBIDDEN, str(error))
        except FileNotFoundError as error:
            self.text(HTTPStatus.NOT_FOUND, str(error))
        except (OSError, RuntimeError, ValueError) as error:
            self.text(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))

    def do_DELETE(self) -> None:
        if not self.require_auth():
            return
        parts, query = self.route()
        if len(parts) != 3 or parts[:2] != ["v1", "jobs"]:
            self.text(HTTPStatus.NOT_FOUND, "not found")
            return
        try:
            root, metadata = self.server.state.require_session(parts[2], self.session(query))
            process_id = int(metadata.get("powershell_pid", 0))
            if process_id and self.server.state.processes(process_id):
                from pywinauto import Application

                if any(int(item["ProcessId"]) != process_id for item in self.server.state.processes(process_id)):
                    raise OSError("cannot clean up while restoration children are running")
                app = Application(backend="uia").connect(process=int(metadata.get("window_pid", process_id)))
                app.top_window().close()
                app.wait_for_process_exit(timeout=10)
            archive = self.server.state.evidence_path(parts[2], self.session(query))
            archive.parent.mkdir(exist_ok=True)
            archive.write_bytes(self.server.state.evidence(parts[2], self.session(query)))
            shutil.rmtree(root)
            self.text(HTTPStatus.OK, "cleaned=true\n")
        except PermissionError as error:
            self.text(HTTPStatus.FORBIDDEN, str(error))
        except OSError as error:
            self.text(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))


class AgentServer(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], state: AgentState) -> None:
        super().__init__(address, Handler)
        self.state = state


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    arguments = parser.parse_args()
    config = load_config(arguments.config)
    state = AgentState(config)
    server = AgentServer(
        (config.get("bind", "127.0.0.1"), int(config.get("port", 8765))),
        state,
    )
    print(f"Windows GUI agent listening on {server.server_address[0]}:{server.server_address[1]}")
    server.serve_forever()


if __name__ == "__main__":
    main()
