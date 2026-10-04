#!/usr/bin/env python3
"""Real noVNC RFB disconnect/reconnect, independent of the Core transport."""
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit
from playwright.sync_api import sync_playwright


def run(config, output):
    if len(config.get("vnc_password", "")) != 8:
        raise ValueError("missing or invalid vnc_password before RFB connection")
    endpoint = config["endpoint"].rstrip("/")
    path = f"/v1/jobs/{config['job']}"
    query = "?session=" + config["session"]
    def request(action, method="GET"):
        req = urllib.request.Request(endpoint + path + "/" + action + query,
                                     headers={"Authorization": "Bearer " + config["token"],
                                              "User-Agent": "MosaicRestore-P5/1.0"}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.read().decode()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            (output / "last-http-error.json").write_text(json.dumps({"action": action, "status": error.code, "detail": detail}))
            raise
    output.mkdir(parents=True, exist_ok=True)
    events = []
    with sync_playwright() as browser:
        chromium = browser.chromium.launch(headless=True, args=["--no-sandbox"])
        page = chromium.new_page(viewport={"width": 1280, "height": 900})
        page.goto(config["desktop_url"].rstrip("/") + "/vnc.html", wait_until="domcontentloaded", timeout=20000)
        page.evaluate("""() => { document.body.innerHTML = '<div id="screen" style="width:1280px;height:800px"></div>'; }""")
        def connect():
            page.evaluate("""async config => {
                const {default:RFB} = await import('/core/rfb.js');
                const url = new URL(config.desktop_url);
                url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
                url.pathname = '/websockify'; url.search='';
                window.connected=false; window.disconnected=false;
                window.rfb = new RFB(document.getElementById('screen'), url.href,
                                    {credentials:{password:config.vnc_password}});
                window.rfb.addEventListener('connect',()=>window.connected=true);
                window.rfb.addEventListener('disconnect',()=>window.disconnected=true);
                window.rfb.addEventListener('securityfailure',e=>window.rfbFailure=e.detail.reason||'VNC authentication failed');
                window.rfb.addEventListener('credentialsrequired',()=>window.rfbFailure='VNC credentials missing');
                window.rfb.addEventListener('desktopname',e=>window.desktopName=e.detail.name);
            }""", config)
            page.wait_for_function("window.connected === true || window.rfbFailure || window.disconnected", timeout=15000)
            if not page.evaluate("window.connected"):
                raise RuntimeError(page.evaluate("window.rfbFailure || 'RFB disconnected before connection'"))
            page.wait_for_timeout(750)
            size = page.locator("canvas").evaluate("c => [c.width,c.height]")
            if size[0] < 100 or size[1] < 100:
                raise RuntimeError("no desktop framebuffer received")
            return {"desktop_name": page.evaluate("window.desktopName"), "framebuffer": size}
        before = connect()
        if config.get("preconnect"):
            (output / "viewer-ready").write_text("connected")
            deadline = time.monotonic() + 120
            while not (output / "allow-reconnect").exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError("GUI launch was not ready within preconnected viewer window")
                page.wait_for_timeout(100)
        request("desktop-checkpoint", "POST")
        if config.get("local_cpu"):
            import p5_runtime_guards
            p5_runtime_guards.verify(config, output)
        page.screenshot(path=str(output / "novnc-before.png"))
        events.append({"event": "connected", "at": time.time(), **before})
        page.evaluate("window.rfb.disconnect()")
        page.wait_for_function("window.disconnected === true", timeout=10000)
        events.append({"event": "rfb-disconnected", "at": time.time()})
        (output / "desktop-reconnect-events.json").write_text(json.dumps(events))
        dropped = False
        try:
            request("disconnect", "POST")
        except urllib.error.HTTPError as error:
            dropped = error.code >= 500
        except (OSError, __import__('http.client', fromlist=['HTTPException']).HTTPException):
            dropped = True
        if not dropped:
            raise RuntimeError("agent transport did not disconnect")
        after = connect()
        events.append({"event": "rfb-reconnected", "at": time.time(), **after})
        (output / "desktop-reconnect-events.json").write_text(json.dumps(events))
        if before != after:
            raise RuntimeError("desktop name/framebuffer changed on reconnect")
        reply = request("reconnect", "POST")
        if "session_id=" + config["session"] not in reply:
            raise RuntimeError("agent session changed")
        page.screenshot(path=str(output / "novnc-after.png"))
        events.append({"event": "rfb-reconnected", "at": time.time(), **after})
        (output / "desktop-reconnect.json").write_text(json.dumps({"events": events, "job": config["job"],
            "session": config["session"], "fixture": bool(config.get("fixture")), "transport_dropped": dropped}, indent=2))
        chromium.close()


if __name__ == "__main__":
    run(json.load(sys.stdin), Path(sys.argv[1]))
