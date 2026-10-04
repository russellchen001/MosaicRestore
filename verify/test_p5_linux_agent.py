#!/usr/bin/env python3
"""Provider/session security and fail-closed tests; GUI tested in actual container."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from argparse import Namespace
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "adapters"))
import linux_gui_agent as agent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_p5_linux import Test as Acceptance


class Tests(unittest.TestCase):
    def connection_args(self, config):
        path = Path(self.temp.name) / "connection.json"
        path.write_text(__import__("json").dumps(config))
        return Namespace(connection=path, output=Path(self.temp.name) / "acceptance",
                         minutes=3, offline=True, local_cpu=False)

    def test_legacy_password_is_normalized_before_rfb(self):
        run = Acceptance(self.connection_args({"password": "12345678"}))
        self.assertEqual(run.connection["vnc_password"], "12345678")

    def test_missing_password_fails_before_desktop_connection(self):
        with self.assertRaisesRegex(ValueError, "vnc_password"):
            Acceptance(self.connection_args({}))
        self.assertFalse((Path(self.temp.name) / "acceptance").exists())

    def test_conflicting_passwords_fail_before_desktop_connection(self):
        with self.assertRaisesRegex(ValueError, "conflicting"):
            Acceptance(self.connection_args({"password": "12345678", "vnc_password": "87654321"}))

    def test_upload_timeout_is_bounded_without_extending_control_requests(self):
        run = Acceptance(self.connection_args({"vnc_password": "12345678",
                         "endpoint": "https://example.invalid", "token": "test-only"}))
        with patch("run_p5_linux.urllib.request.urlopen") as request:
            request.return_value.__enter__.return_value.read.return_value = b"ok"
            run.request("input", "job", method="PUT", body=b"test")
            self.assertEqual(request.call_args.kwargs["timeout"], 60)
            run.request("cancel", "job", method="POST")
            self.assertEqual(request.call_args.kwargs["timeout"], 10)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = agent.LinuxState({"root": self.temp.name, "application_path": "/missing/lada-cli",
                                      "ffprobe_path": "/missing/ffprobe", "command_template": "{application} --input {input} --output {output}"})
        self.session = self.state.open_session("job")

    def tearDown(self):
        self.temp.cleanup()

    def test_same_session(self):
        self.assertEqual(self.session, self.state.open_session("job"))

    def test_path_traversal(self):
        with self.assertRaises(ValueError):
            self.state.open_session("../outside")

    def test_missing_runtime_fails(self):
        with self.assertRaises(RuntimeError):
            self.state.health()

    def test_wrong_session_cannot_focus_desktop(self):
        with patch.object(self.state, "window") as focus:
            for operation in (self.state.checkpoint, self.state.reconnect):
                with self.assertRaises(PermissionError):
                    operation("job", "wrong")
            focus.assert_not_called()

    def test_no_checkpoint_reconnect_rejected(self):
        root, meta = self.state.require_session("job", self.session)
        with patch.object(self.state, "window", return_value=(root, meta)):
            with self.assertRaises(RuntimeError):
                self.state.reconnect("job", self.session)

    def test_checkpoint_requires_running_children(self):
        root, meta = self.state.require_session("job", self.session)
        (root / "task.pid").write_text("42")
        with patch.object(self.state, "window", return_value=(root, meta)), patch.object(self.state, "processes", return_value=[]):
            with self.assertRaises(RuntimeError):
                self.state.checkpoint("job", self.session)

    def test_changed_process_start_time_rejected(self):
        root, meta = self.state.require_session("job", self.session)
        meta.update(transport_drops=1, desktop_checkpoint={"task": {"ProcessId": 42, "StartTicks": "1"},
                                                       "status": {"progress": 10}})
        with patch.object(self.state, "window", return_value=(root, meta)), \
             patch.object(self.state, "processes", return_value=[{"ProcessId": 42, "StartTicks": "2"}]), \
             patch.object(self.state, "status", return_value={"state": "running", "progress": 20}):
            with self.assertRaises(RuntimeError):
                self.state.reconnect("job", self.session)

    def test_progress_regression_rejected(self):
        root, meta = self.state.require_session("job", self.session)
        task = {"ProcessId": 42, "StartTicks": "1"}
        meta.update(transport_drops=1, desktop_checkpoint={"task": task, "restoration_task": task, "status": {"progress": 10}})
        with patch.object(self.state, "window", return_value=(root, meta)), patch.object(self.state, "processes", return_value=[task]), \
             patch.object(self.state, "status", return_value={"state": "running", "progress": 5}):
            with self.assertRaises(RuntimeError):
                self.state.reconnect("job", self.session)


if __name__ == "__main__":
    unittest.main()
