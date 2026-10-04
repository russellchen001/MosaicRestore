#!/usr/bin/env python3
"""Offline desktop tests only; manifest explicitly rejects real acceptance."""
import argparse
from pathlib import Path
from http.server import ThreadingHTTPServer
import sys
sys.path.insert(0, "/opt/p5")
import linux_gui_agent as agent

class Fixture(agent.LinuxState):
    def readiness(self, job, session):
        root, meta = self.require_session(job, session)
        agent.inspect(["xdpyinfo"])
        self.screenshot(root / "desktop-ready.png")
        (root / "gpu.txt").write_text("OFFLINE FIXTURE: no CUDA GPU")
        meta["fixture"] = True
        agent.protocol.atomic_json(self.metadata_path(job), meta)

parser = argparse.ArgumentParser()
parser.add_argument("--config", type=Path)
config = agent.protocol.load_config(parser.parse_args().config)
config["application_path"] = "/opt/lada/.venv/bin/python"
config["command_template"] = "{application} /opt/p5/p5_linux_fixture_task.py {input} {output}"
server = ThreadingHTTPServer(("0.0.0.0", 8765), agent.LinuxHandler)
server.state = Fixture(config)
server.serve_forever()
