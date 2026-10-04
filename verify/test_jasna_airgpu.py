#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("windows_agent", ROOT / "adapters/windows_gui_agent.py")
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


class JasnaAirGpuTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        app, ffprobe = root / "jasna.exe", root / "ffprobe.exe"
        detector, restorer = root / "detector.pt", root / "restorer.pth"
        cache = root / "model_weights"
        cache.mkdir()
        for path in (app, ffprobe, detector, restorer, cache / "t4.engine"):
            path.write_bytes(b"fixture")
        self.state = agent.AgentState({
            "root": str(root / "jobs"), "application_path": str(app),
            "ffprobe_path": str(ffprobe), "command_template": "& {application} --input {input} --output {output}",
            "jasna_version": "0.10.0", "jasna_models": [str(detector), str(restorer)],
            "tensorrt_cache": str(cache), "token": "fixture",
        })
        self.job = "headless-fixture"
        self.session = self.state.open_session(self.job)
        (self.state.job_root(self.job) / "input.mp4").write_bytes(b"video")

    def tearDown(self):
        self.temp.cleanup()

    @mock.patch.object(subprocess, "run")
    def test_pinned_readiness_requires_cached_jasna(self, run):
        run.side_effect = [
            subprocess.CompletedProcess([], 0, "Tesla T4, 610.0\n", ""),
            subprocess.CompletedProcess([], 0, "Jasna 0.10.0\n", ""),
        ]
        self.state.headless_readiness(self.job, self.session)
        metadata = json.loads(self.state.metadata_path(self.job).read_text())
        self.assertEqual(metadata["runtime"], "jasna-headless")
        self.assertEqual(metadata["tensorrt_engines"], ["t4.engine"])

    @mock.patch.object(subprocess, "Popen")
    def test_headless_launch_records_zero_gui_actions(self, popen):
        popen.return_value.pid = 4321
        self.state.start_headless(self.job, self.session)
        metadata = json.loads(self.state.metadata_path(self.job).read_text())
        self.assertEqual(metadata["powershell_pid"], 4321)
        self.assertEqual(metadata["gui_actions"], 0)
        self.assertEqual(metadata["runtime"], "jasna-headless")


if __name__ == "__main__":
    unittest.main(verbosity=2)
