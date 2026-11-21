"""Open the installed Chromium launcher on the fixture-only display."""
import importlib.util
from functools import partial
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
from queue import Queue
import secrets
import subprocess
import sys
from threading import Thread
import time


def check(state, fixture, vm, policy, frames):
    assert os.getuid() != 0
    spec = importlib.util.spec_from_file_location("webgl_probe", fixture / "chromium-gpu.py")
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    key = ["gsettings", "get", "org.y700.chromium", "hardware-acceleration"]
    assert subprocess.check_output(key, text=True).strip() == "false"
    if policy == "hardware":
        subprocess.run(["gsettings", "set", "org.y700.chromium", "hardware-acceleration", "true"], check=True)
    setting = subprocess.check_output(key, text=True).strip()
    assert setting == ("true" if policy == "hardware" else "false")
    print(f"WINDOW_POLICY isolated_profile=1 setting={setting}", flush=True)
    # Only layout changes. Retain the original shader, 60 per-frame readbacks and report.
    html = (fixture / "chromium-gpu.html").read_text()
    style = ("<style>canvas{position:fixed;inset:0;width:100vw!important;height:100vh!important}"
             "pre{display:none}body{margin:0}</style>")
    assert html.count("<canvas ") == 1
    page = html.replace("<canvas ", style + "<canvas ").encode()
    if policy == "software":
        html = page.decode()
        marker = "    status.textContent = JSON.stringify(report, null, 2);"
        assert html.count(marker) == 1
        html = html.replace("async function run() {", (fixture / "software-control.js").read_text()
                            + "\nasync function run() {")
        page = html.replace(marker, '    if (report.error === "WebGL 2 context unavailable")'
                            ' await drawSoftwareControl();\n' + marker).encode()
    route = "/" + secrets.token_hex(16)
    reports = Queue(maxsize=1)
    handler = partial(probe.ProbeHandler, route=route, page=page, reports=reports)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_port}{route}?frames={frames}"
        command = ["/usr/bin/chromium", f"--user-data-dir={Path.home() / 'profile'}",
                   "--ozone-platform=x11", "--window-size=640,480", "--window-position=0,0",
                   "--force-device-scale-factor=1", "--no-first-run", "--no-default-browser-check",
                   "--disable-background-networking", "--kiosk", "--app=" + url]
        browser = subprocess.Popen(command, stdout=subprocess.DEVNULL)
        try:
            report = reports.get(timeout=125)
            verdict = probe.verdict(report, frames, "vulkan")
            print("WINDOW_WEBGL " + json.dumps({"result": verdict, "renderer": report.get("renderer"),
                                                "error": report.get("error"), "frames": report.get("frames"),
                                                "elapsed_ms": report.get("elapsedMs")}), flush=True)
            if policy == "software" and verdict == "webgl-error":
                assert report.get("error") == "WebGL 2 context unavailable" and report["frames"] == 0
                control = report["canvas2d"]
                assert control["frames"] == frames and control["elapsedMs"] > 0, control
                print("WINDOW_CANVAS2D " + json.dumps(control), flush=True)
            elif vm or policy == "software":
                assert verdict == "software-renderer" and report["frames"] == frames, verdict
            else:
                assert verdict == "adreno-730-rendered", verdict
            # The private X server contains only this application's fresh session.
            tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
            windows = [line.split()[0] for line in tree.splitlines()
                       if "Y700 Chromium WebGL probe" in line and "chromium" in line.lower()]
            assert len(windows) == 1, windows
            info = subprocess.check_output(["xwininfo", "-id", windows[0]], text=True)
            assert "Map State: IsViewable" in info
            print("WINDOW_BROWSER mapped=1 ozone=x11 private_profile=1", flush=True)
            (state / "client/browser-ready").touch()
            deadline = time.monotonic() + 15
            while not (state / "display-checked").exists():
                assert browser.poll() is None and time.monotonic() < deadline, "presentation timeout"
                time.sleep(.15)
        finally:
            browser.terminate()
            try:
                browser.wait(timeout=4)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait()
            server.shutdown()


if __name__ == "__main__":
    check(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == "vm", sys.argv[4], int(sys.argv[5]))
