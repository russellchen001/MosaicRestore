#!/usr/bin/env python3
"""Offline behavior tests: fake desktop only, never real GUI acceptance."""
import importlib.util
import io
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import zipfile
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agent = load("p5agent", ROOT / "adapters/windows_gui_agent.py")
runner = load("p5runner", ROOT / "verify/run_p5_real.py")
gate = load("p5success", ROOT / "verify/p5_success_adapter.py")


class OneclickTests(unittest.TestCase):
    def test_success_gate_requires_completion_then_reconnect_before_download(self):
        events = []
        session = "fixture-session"
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr("manifest.json", json.dumps({"session_id": session, "transport_drops": 1,
                             "reconnect_processes": [{"ProcessId": 10}], "action_receipt": "fixture-only"}))
            for name in ("desktop-ready.png", "action-start.png", "action-reconnect.png"):
                archive.writestr(name, b"\x89PNG\r\n\x1a\nfixture-only")
        class DroppedConnection:
            def request(self, *args, **kwargs):
                events.append("disconnect")
            def getresponse(self):
                raise http.client.RemoteDisconnected("fixture reset")
            def close(self):
                pass
        class Relay:
            prefix = ""
            profile = {"token": "fixture-token"}
            def connection(self):
                return DroppedConnection()
            def request(self, method, path):
                action = path.split("?")[0].split("/")[-1]
                events.append(action)
                if action == "status":
                    return f"state=succeeded\nsession_id={session}\n".encode()
                if action == "reconnect":
                    return f"session_id={session}\nagent=ready\n".encode()
                return payload.getvalue()
        gate.before_download(Relay(), "fixture", session, self.root)
        events.append("download")  # Production adapter is only called after gate returns.
        self.assertEqual(events, ["status", "disconnect", "reconnect", "evidence", "download"])
        self.assertEqual(json.loads((self.root / "success-session.json").read_text())["session"], session)
        incomplete = Relay()
        incomplete.request = lambda *args: b"state=running\nsession_id=fixture-session\n"
        with self.assertRaisesRegex(RuntimeError, "must succeed"):
            gate.before_download(incomplete, "fixture", session, self.root)

    def test_primary_runner_finishes_without_optional_cancel(self):
        output = self.root / "primary"
        output.mkdir()
        events = []
        test = types.SimpleNamespace(output=output, deadline=runner.time.monotonic()+90, jobs=[], checks=[])
        def open_session(job):
            events.append("session")
            test.jobs.append((job, "session"))
            return "session"
        test.open = open_session
        test.url = runner.urllib.parse.urlsplit("https://fixture.invalid")
        test.token = "fixture-only"
        test.evidence = lambda *args, **kwargs: {"output.mp4_sha256": agent.hashlib.sha256(b"result").hexdigest()}
        test.passed = test.checks.append
        def command(args, **kwargs):
            if args[0] == "ffmpeg":
                Path(args[-1]).write_bytes(b"synthetic")
            return types.SimpleNamespace(stdout=b'{"streams":[{"codec_type":"video"}]}')
        class CoreProcess:
            returncode = 0
            def __init__(self, *args, **kwargs):
                events.append("restore")
                (output / "output.mp4").write_bytes(b"result")
            def poll(self):
                return 0
        args = types.SimpleNamespace(core=self.root / "core", cancel_if_time=True)
        with patch.object(runner, "Acceptance", return_value=test), patch.object(runner.subprocess, "run", side_effect=command), patch.object(runner.subprocess, "Popen", CoreProcess):
            with redirect_stdout(io.StringIO()):
                runner.run(args)
        report = json.loads((output / "report.json").read_text())
        self.assertEqual(events, ["session", "restore"])
        self.assertEqual(report["primary_chain"], "PASS")
        self.assertTrue(report["cancellation"].startswith("SKIP"))

    def test_optional_bundle_manifest_and_windows_dependencies(self):
        path = os.environ.get("MOSAIC_P5_BUNDLE")
        if not path:
            self.skipTest("bundle path not supplied")
        with zipfile.ZipFile(path) as archive:
            self.assertIsNone(archive.testzip())
            manifest = json.loads(archive.read("SHA256.json"))
            for name, expected in manifest.items():
                self.assertEqual(agent.hashlib.sha256(archive.read(name)).hexdigest(), expected)
            for name in ("windows_gui_agent.py", "deploy_windows_agent.ps1", "deploy_windows_agent.cmd"):
                self.assertEqual(archive.read(name), (ROOT / "adapters" / name).read_bytes())
            for abi in ("311", "312"):
                for package in ("pywinauto", "pywin32", "pillow", "comtypes", "six"):
                    wheels = [name for name in archive.namelist() if name.startswith(f"wheels/{abi}/{package}-")]
                    self.assertEqual(len(wheels), 1)
                    with zipfile.ZipFile(io.BytesIO(archive.read(wheels[0]))) as wheel:
                        self.assertTrue(any("license" in name.lower() for name in wheel.namelist()))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.state = agent.AgentState({"root": str(self.root / "jobs"), "application_path": str(self.root / "app"),
                                       "ffprobe_path": str(self.root / "probe"), "command_template": "& {application}"})
        (self.root / "app").touch()
        (self.root / "probe").touch()
        self.session = self.state.open_session("fixture")
        self.job = self.state.job_root("fixture")
        self.metadata = agent.read_json(self.state.metadata_path("fixture"))
        self.metadata.update(powershell_pid=10, gui_actions=3)
        agent.atomic_json(self.state.metadata_path("fixture"), self.metadata)
        self.window = types.SimpleNamespace(set_focus=lambda: None, close=lambda: None,
                     capture_as_image=lambda: types.SimpleNamespace(save=lambda path: Path(path).write_bytes(b"fixture-only-image")))
        self.app = types.SimpleNamespace(connect=lambda **kwargs: self.app, top_window=lambda: self.window,
                                        wait_for_process_exit=lambda **kwargs: None)
        self.uia = types.SimpleNamespace(Application=lambda **kwargs: self.app,
                                         keyboard=types.SimpleNamespace(send_keys=lambda *args, **kwargs: None))

    def tearDown(self):
        self.temporary.cleanup()

    def test_cancel_records_exit_not_just_ctrl_c(self):
        parent = {"ProcessId": 10, "ParentProcessId": 1, "Name": "powershell.exe"}
        child = {"ProcessId": 20, "ParentProcessId": 10, "Name": "lada-cli.exe"}
        with patch.dict("sys.modules", pywinauto=self.uia), patch.object(self.state, "processes", side_effect=[[parent, child], [parent], []]):
            self.state.cancel("fixture", self.session)
        metadata = agent.read_json(self.state.metadata_path("fixture"))
        self.assertTrue(metadata["powershell_exited"])
        self.assertEqual(metadata["cancel_after"], [])
        self.assertEqual(metadata["cancel_before"], [parent, child])
        self.assertEqual(self.state.status("fixture", self.session)["state"], "cancelled")

    def test_surviving_child_fails_cancellation(self):
        parent = {"ProcessId": 10, "ParentProcessId": 1}
        child = {"ProcessId": 20, "ParentProcessId": 10}
        with patch.dict("sys.modules", pywinauto=self.uia), patch.object(self.state, "processes", side_effect=[[parent, child], [parent], [child]]):
            with self.assertRaisesRegex(RuntimeError, "survived"):
                self.state.cancel("fixture", self.session)
        self.assertFalse(agent.read_json(self.state.metadata_path("fixture")).get("powershell_exited", False))

    def test_reconnect_preserves_identity_and_captures_desktop(self):
        with patch.dict("sys.modules", pywinauto=self.uia), patch.object(self.state, "processes", return_value=[{"ProcessId": 10}]):
            self.state.reconnect("fixture", self.session)
        metadata = agent.read_json(self.state.metadata_path("fixture"))
        self.assertEqual(metadata["session_id"], self.session)
        self.assertEqual(metadata["reconnect_processes"], [{"ProcessId": 10}])
        self.assertGreater((self.job / "action-reconnect.png").stat().st_size, 0)
        with self.assertRaises(PermissionError):
            self.state.reconnect("fixture", "wrong-session")

    def test_evidence_hashes_and_utf16_progress(self):
        (self.job / "input.mp4").write_bytes(b"input")
        (self.job / "output.mp4").write_bytes(b"output")
        (self.job / "run.log").write_text("Processing: 42%", encoding="utf-16")
        with patch.object(self.state, "processes", return_value=[]):
            payload = self.state.evidence("fixture", self.session)
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["output.mp4_sha256"], agent.hashlib.sha256(b"output").hexdigest())
            self.assertNotIn("input.mp4", archive.namelist())
        self.assertEqual(self.state.status("fixture", self.session)["progress"], 42)

    def test_real_runner_rejects_non_https_and_missing_exit_proof(self):
        path = self.root / "connection.json"
        path.write_text(json.dumps({"endpoint": "http://127.0.0.1:9999", "token": "fixture"}))
        with self.assertRaisesRegex(RuntimeError, "HTTPS"):
            runner.Acceptance(types.SimpleNamespace(connection=path, minutes=2, output=self.root / "report"))
        check = object.__new__(runner.Acceptance)
        check.output = self.root
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            manifest = dict(self.metadata, session_id=self.session, gui_actions=3)
            archive.writestr("manifest.json", json.dumps(manifest))
            for name in ("desktop-ready.png", "action-start.png", "action-cancel.png", "gpu.txt"):
                archive.writestr(name, b"fixture-only")
        check.action = lambda *args, **kwargs: payload.getvalue()
        with self.assertRaisesRegex(RuntimeError, "process exit"):
            check.evidence("fixture", self.session, "missing-exit", cancelled=True)

    def test_http_drop_and_cleanup_preserve_authenticated_evidence(self):
        self.state.config["token"] = "fixture-token"
        class QuietHandler(agent.Handler):
            def log_message(self, *args):
                pass
        server = agent.AgentServer(("127.0.0.1", 0), self.state)
        server.RequestHandlerClass = QuietHandler
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def request(method, action, session=self.session, token="fixture-token"):
            client = http.client.HTTPConnection(*server.server_address, timeout=2)
            path = f"/v1/jobs/fixture{('/' + action) if action else ''}?session={session}"
            try:
                client.request(method, path, headers={"Authorization": "Bearer " + token})
                reply = client.getresponse()
                return reply.status, reply.read()
            finally:
                client.close()
        try:
            self.assertEqual(request("GET", "evidence", token="wrong")[0], 401)
            with self.assertRaises((OSError, http.client.HTTPException)):
                request("POST", "disconnect")
            self.assertEqual(agent.read_json(self.state.metadata_path("fixture"))["transport_drops"], 1)
            with patch.dict("sys.modules", pywinauto=self.uia), patch.object(self.state, "processes", return_value=[{"ProcessId": 10}]):
                code, payload = request("POST", "reconnect")
            self.assertEqual(code, 200)
            self.assertIn(self.session.encode(), payload)
            with patch.object(self.state, "processes", return_value=[]):
                self.assertEqual(request("DELETE", "")[0], 200)
            self.assertFalse(self.job.exists())
            code, payload = request("GET", "evidence")
            self.assertEqual(code, 200)
            with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                self.assertEqual(json.loads(archive.read("manifest.json"))["session_id"], self.session)
            self.assertEqual(request("GET", "evidence", session="wrong")[0], 403)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
