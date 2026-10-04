#!/usr/bin/env python3
"""Linux X11 implementation of the existing standalone HTTP GUI contract."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time
from http.server import ThreadingHTTPServer
import windows_gui_agent as protocol


def inspect(command):
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=10).stdout.strip()


class LinuxState(protocol.AgentState):
    def health(self):
        super().health()
        if os.environ.get("P5_VNC_PASSWORD"):
            try:
                subprocess.run([str(Path(self.config["application_path"]).parent / "python"),
                                "/opt/p5/p5_desktop_probe.py", "--local"],
                               check=True, capture_output=True, timeout=25)
            except (OSError, subprocess.SubprocessError) as error:
                raise RuntimeError("desktop VNC/Xfce/WebSocket/RFB readiness failed") from error

    def screenshot(self, path):
        import pyautogui
        pyautogui.screenshot().save(path)

    def window(self, job):
        root, meta = self.require_session(job, protocol.read_json(self.metadata_path(job)).get("session_id", ""))
        window = str(meta["window_id"])
        pid = int(inspect(["xdotool", "getwindowpid", window]))
        if pid != meta["terminal_pid"]:
            raise RuntimeError("desktop window identity changed")
        inspect(["xdotool", "windowactivate", "--sync", window])
        return root, meta

    def open_session(self, job):
        session = super().open_session(job)
        meta = protocol.read_json(self.metadata_path(job))
        meta.update(runtime="linux-x11-pyautogui", display=os.environ.get("DISPLAY", ""))
        protocol.atomic_json(self.metadata_path(job), meta)
        return session

    def readiness(self, job, session):
        root, _ = self.require_session(job, session)
        self.health()
        inspect(["xdpyinfo"])
        gpu = inspect(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"])
        if not gpu:
            raise RuntimeError("GPU missing")
        inspect([str(Path(self.config["application_path"]).parent / "python"), "-c",
                 "import torch; assert torch.cuda.is_available(); x=torch.ones(1,device='cuda'); assert x.item()==1"])
        weights = Path(self.config["weights"])
        subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=weights, check=True,
                       capture_output=True, timeout=10)
        self.screenshot(root / "desktop-ready.png")
        (root / "gpu.txt").write_text(gpu)

    def processes(self, process_id):
        inventory = []
        for directory in Path("/proc").glob("[0-9]*"):
            try:
                raw = (directory / "stat").read_text()
                fields = raw[raw.rfind(")") + 2:].split()
                inventory.append({"ProcessId": int(directory.name), "ParentProcessId": int(fields[1]),
                                  "StartTicks": fields[19], "Name": (directory / "comm").read_text().strip()})
            except (OSError, ValueError, IndexError):
                continue
        ids = {process_id}
        while True:
            expanded = ids | {p["ProcessId"] for p in inventory if p["ParentProcessId"] in ids}
            if expanded == ids:
                return [p for p in inventory if p["ProcessId"] in ids]
            ids = expanded

    def build_script(self, root):
        command = self.config["command_template"].format(
            application=shlex.quote(self.config["application_path"]),
            input=shlex.quote(str(root / "input.mp4")), output=shlex.quote(str(root / "output.mp4")))
        script = root / "run-visible.sh"
        script.write_text("#!/bin/bash\nset -o pipefail\n"
                          f"cd {shlex.quote(str(root))}\n"
                          "echo $$ > task.pid\necho running > state.txt\n"
                          "trap 'echo cancelled > state.txt; exit 130' INT TERM\n"
                          f"{command} 2>&1 | tee run.log\nrc=${{PIPESTATUS[0]}}\n"
                          "if [ \"$rc\" = 0 ] && [ -s output.mp4 ]; then echo succeeded > state.txt; "
                          "else echo failed > state.txt; echo exit=$rc > error.txt; fi\n")
        return script

    def start(self, job, session):
        import pyautogui as gui
        root, meta = self.require_session(job, session)
        if meta.get("action_receipt"):
            return meta["action_receipt"]  # Idempotent; never relaunch this job.
        if not (root / "input.mp4").is_file():
            raise FileNotFoundError("uploaded input missing")
        script = self.build_script(root)
        self.screenshot(root / "action-before.png")
        title = "Mosaic-" + job
        gui.hotkey("alt", "f2")
        time.sleep(0.5)
        gui.write("xfce4-terminal --disable-server --title=" + title, interval=0.01)
        gui.press("enter")
        deadline = time.monotonic() + 10
        while True:
            try:
                window = inspect(["xdotool", "search", "--onlyvisible", "--name", "^" + title + "$"]).splitlines()[0]
                break
            except (subprocess.SubprocessError, IndexError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("visible terminal was not created by GUI")
                time.sleep(0.2)
        pid = int(inspect(["xdotool", "getwindowpid", window]))
        inspect(["xdotool", "windowactivate", "--sync", window])
        gui_command = "bash " + shlex.quote(str(script))
        gui.write(gui_command, interval=0.005)
        gui.press("enter")
        time.sleep(0.2)
        self.screenshot(root / "action-start.png")
        receipt = "x11-keyboard:" + job + ":" + window
        meta.update(state="running", started_at=time.time(), terminal_pid=pid, powershell_pid=pid,
                    window_id=window, action_receipt=receipt, gui_actions=5, launch_processes=self.processes(pid),
                    gui_command=gui_command, gui_transport="pyautogui-X11-keyboard", script_sha256=__import__("hashlib").sha256(script.read_bytes()).hexdigest())
        protocol.atomic_json(self.metadata_path(job), meta)
        return receipt

    def checkpoint(self, job, session):
        self.require_session(job, session)
        root, meta = self.window(job)
        status = self.status(job, session)
        task = int((root / "task.pid").read_text())
        tasks = self.processes(task)
        if status["state"] != "running" or len(tasks) < 2:
            raise RuntimeError("reconnect requires an active restoration process, not an idle terminal")
        identity = next(p for p in tasks if p["ProcessId"] == task)
        restoration = next((p for p in tasks if p["ParentProcessId"] == task and
                           (p["Name"].startswith("python") or p["Name"] == "lada-cli")), None)
        if not restoration:
            raise RuntimeError("actual Lada process identity is missing")
        meta["desktop_checkpoint"] = {"task": identity, "restoration_task": restoration, "processes": tasks, "status": status,
                                      "window_id": meta["window_id"], "display": meta["display"], "at": time.time()}
        protocol.atomic_json(self.metadata_path(job), meta)
        self.screenshot(root / "desktop-before-disconnect.png")

    def reconnect(self, job, session):
        self.require_session(job, session)
        root, meta = self.window(job)
        checkpoint = meta.get("desktop_checkpoint")
        if not checkpoint or not meta.get("transport_drops"):
            raise RuntimeError("missing live desktop checkpoint/transport drop")
        task = checkpoint["task"]
        processes = self.processes(task["ProcessId"])
        same = any(p["ProcessId"] == task["ProcessId"] and p["StartTicks"] == task["StartTicks"] for p in processes)
        restoration = checkpoint.get("restoration_task", {})
        same_restoration = any(p["ProcessId"] == restoration.get("ProcessId") and
                               p["StartTicks"] == restoration.get("StartTicks") for p in processes)
        status = self.status(job, session)
        if not same or not same_restoration or status["state"] != "running" or status["progress"] < checkpoint["status"]["progress"]:
            raise RuntimeError("task exited/restarted or progress regressed during reconnect")
        self.screenshot(root / "action-reconnect.png")
        meta.update(reconnect_processes=processes, reconnected_at=time.time(), reconnect_status=status,
                    same_task_verified=True)
        protocol.atomic_json(self.metadata_path(job), meta)

    def cancel(self, job, session):
        import pyautogui as gui
        self.require_session(job, session)
        root, meta = self.window(job)
        task = int((root / "task.pid").read_text())
        before = self.processes(task)
        if len(before) < 2 or self.status(job, session)["state"] != "running":
            raise RuntimeError("no active restoration task to cancel")
        gui.hotkey("ctrl", "c")
        self.screenshot(root / "action-cancel.png")
        deadline = time.monotonic() + 10
        while any(self.processes(p["ProcessId"]) for p in before):
            if time.monotonic() >= deadline:
                raise RuntimeError("GUI Ctrl-C left task processes alive")
            time.sleep(0.2)
        terminal = meta["terminal_pid"]
        gui.hotkey("alt", "f4")
        end = time.monotonic() + 10
        while self.processes(terminal):
            if time.monotonic() >= end:
                raise RuntimeError("terminal process survived GUI close")
            time.sleep(0.2)
        meta.update(state="cancelled", cancelled_at=time.time(), cancel_before=before, cancel_after=[],
                    task_exited=True, terminal_exited=True)
        protocol.atomic_json(self.metadata_path(job), meta)
        (root / "state.txt").write_text("cancelled")

    def evidence(self, job, session):
        import io
        import zipfile
        root, meta = self.require_session(job, session)
        meta.update(observed_status=self.status(job, session))
        protocol.atomic_json(self.metadata_path(job), meta)
        output = io.BytesIO(super().evidence(job, session))
        with zipfile.ZipFile(output, "a", zipfile.ZIP_DEFLATED) as archive:
            for name in ("action-before.png", "desktop-before-disconnect.png", "task.pid", "run-visible.sh"):
                if (root / name).is_file():
                    archive.write(root / name, name)
        return output.getvalue()


class LinuxHandler(protocol.Handler):
    def do_POST(self):
        parts, query = self.route()
        if len(parts) == 4 and parts[3] == "desktop-checkpoint":
            if not self.require_auth():
                return
            try:
                self.server.state.checkpoint(parts[2], self.session(query))
                self.text(200, "checkpoint=true\n")
            except PermissionError as error:
                self.text(403, str(error))
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                self.text(500, str(error))
        else:
            super().do_POST()

    def do_DELETE(self):
        if not self.require_auth():
            return
        parts, query = self.route()
        if len(parts) != 3 or parts[:2] != ["v1", "jobs"]:
            self.text(404, "not found")
            return
        try:
            state = self.server.state
            session = self.session(query)
            root, meta = state.require_session(parts[2], session)
            task = int((root / "task.pid").read_text())
            if state.processes(task):
                raise RuntimeError("cannot clean an active task")
            saved = state.evidence_path(parts[2], session)
            saved.parent.mkdir(exist_ok=True)
            saved.write_bytes(state.evidence(parts[2], session))
            import pyautogui
            if not meta.get("terminal_exited"):
                state.window(parts[2])
                pyautogui.hotkey("alt", "f4")
            shutil.rmtree(root)
            self.text(200, "cleaned=true\n")
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            self.text(500, str(error))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    config = protocol.load_config(parser.parse_args().config)
    server = ThreadingHTTPServer((config.get("bind", "127.0.0.1"), config.get("port", 8765)), LinuxHandler)
    server.state = LinuxState(config)
    server.serve_forever()
