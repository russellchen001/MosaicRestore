#!/usr/bin/env python3
"""Authenticate a real noVNC WebSocket/RFB desktop before publishing readiness."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from playwright.sync_api import sync_playwright


def probe(url, password, output=None, local=False):
    if len(password) != 8:
        raise ValueError("vnc_password must contain exactly 8 characters")
    started = time.monotonic()
    if local:
        with socket.create_connection(("127.0.0.1", 5901), timeout=3) as sock:
            if not sock.recv(12).startswith(b"RFB 003."):
                raise RuntimeError("VNC socket did not return an RFB banner")
        subprocess.run(["xdpyinfo"], check=True, capture_output=True, timeout=3)
        for process in ("xfce4-session", "xfwm4"):
            subprocess.run(["pgrep", "-x", process], check=True, capture_output=True, timeout=3)
    with sync_playwright() as runtime:
        browser = runtime.chromium.launch(headless=True, args=["--no-sandbox"])
        page = browser.new_page(viewport={"width": 1280, "height": 900})
        response = page.goto(url.rstrip("/") + "/vnc.html", timeout=10000)
        if response.status != 200:
            raise RuntimeError("noVNC HTML unavailable")
        page.evaluate("""async cfg => {
            document.body.innerHTML='<div id="screen" style="width:1280px;height:800px"></div>';
            const {default:RFB}=await import('/core/rfb.js');
            const url=new URL(cfg.url); url.protocol=url.protocol==='https:'?'wss:':'ws:';
            url.pathname='/websockify'; url.search='';
            window.probe={state:'connecting'};
            window.rfb=new RFB(document.getElementById('screen'),url.href,{credentials:{password:cfg.password}});
            rfb.addEventListener('securityfailure',e=>window.probe={state:'failed',reason:e.detail.reason||'VNC authentication failed'});
            rfb.addEventListener('credentialsrequired',()=>window.probe={state:'failed',reason:'VNC credentials missing'});
            rfb.addEventListener('disconnect',()=>{if(probe.state!=='failed') probe={state:'failed',reason:'RFB disconnected before readiness'};});
            rfb.addEventListener('connect',()=>window.probe={state:'connected'});
        }""", {"url": url, "password": password})
        page.wait_for_function("probe.state !== 'connecting'", timeout=15000)
        state = page.evaluate("probe")
        if state["state"] != "connected":
            raise RuntimeError(state.get("reason", "RFB handshake failed"))
        page.wait_for_function("document.querySelector('canvas')?.width >= 100", timeout=5000)
        page.wait_for_timeout(300)
        framebuffer = page.locator("canvas").evaluate("c=>[c.width,c.height]")
        result = {"desktop_ready": True, "rfb_authenticated": True,
                  "framebuffer": framebuffer, "seconds": round(time.monotonic()-started, 3),
                  "x_session_checked": local}
        if output:
            output.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(output / "desktop-ready.png"))
            (output / "desktop-ready.json").write_text(json.dumps(result, indent=2))
        page.evaluate("rfb.disconnect()")
        browser.close()
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:6080")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--connection", type=Path)
    args = parser.parse_args()
    config = json.loads(args.connection.read_text()) if args.connection else {}
    print(json.dumps(probe(config.get("desktop_url", args.url),
                           config.get("vnc_password", config.get("password", os.environ.get("P5_VNC_PASSWORD", ""))),
                           args.output, args.local)))
