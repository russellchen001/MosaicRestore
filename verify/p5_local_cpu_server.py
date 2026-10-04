#!/usr/bin/env python3
"""Local real Lada/CPU desktop validation; never claims NVIDIA readiness."""
import argparse
from pathlib import Path
from http.server import ThreadingHTTPServer
import sys
sys.path.insert(0, "/opt/p5")
import linux_gui_agent as agent


class LocalCPU(agent.LinuxState):
    def readiness(self, job, session):
        root, meta = self.require_session(job, session)
        self.health()
        agent.inspect(["xdpyinfo"])
        agent.inspect([str(Path(self.config["application_path"]).parent / "python"), "-c",
                       "import torch; assert torch.ones(1).item()==1"])
        agent.subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=self.config["weights"], check=True,
                             capture_output=True, timeout=10)
        self.screenshot(root / "desktop-ready.png")
        (root / "gpu.txt").write_text("LOCAL REAL LADA CPU; NVIDIA/CUDA device NOT AVAILABLE")
        meta.update(local_cpu=True, runtime="linux-x11-real-lada-cpu")
        agent.protocol.atomic_json(self.metadata_path(job), meta)


class LocalHandler(agent.LinuxHandler):
    def do_GET(self):
        parts, query = self.route()
        if len(parts) == 4 and parts[3] == "readiness":
            if not self.require_auth():
                return
            session = self.session(query)
            try:
                self.server.state.readiness(parts[2], session)
                self.text(200, f"session_id={session}\ntransport=agent-gui\nagent=ready\ndesktop=ready\ngpu=unavailable\napplication=ready\n")
            except Exception as error:
                self.text(500, str(error))
        else:
            super().do_GET()


parser = argparse.ArgumentParser()
parser.add_argument("--config", type=Path)
config = agent.protocol.load_config(parser.parse_args().config)
config["command_template"] = config["command_template"].replace("--device cuda:0 --fp16", "--device cpu")
server = ThreadingHTTPServer(("0.0.0.0", 8765), LocalHandler)
server.state = LocalCPU(config)
server.serve_forever()
