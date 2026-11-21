"""Check rendered Chromium client pixels against a fixed asymmetric target on the VM-only X server."""

import importlib.util
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import re
import subprocess
import time
import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkX11

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("chart", here / "orient-vm-check.py")
chart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chart)
work = Path("/run/qcam-qa")
wanted = {
    ("main", "left"): "YBGR",
    ("main", "right"): "RGBY",
    ("front", "left"): "GRYB",
    ("front", "right"): "BYRG",
}


def displayed():
    xids = subprocess.check_output(
        [
            "xdotool",
            "search",
            "--onlyvisible",
            "--name",
            "^Y700 camera orientation fixture",
        ],
        text=True,
    ).split()
    assert len(xids) == 1, xids
    window = GdkX11.X11Window.foreign_new_for_display(
        Gdk.Display.get_default(), int(xids[0])
    )
    _, _, width, height = window.get_geometry()
    image = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
    return chart.corners(image, preview=True)


def sandboxed():
    (work / "check-sandbox").touch()
    receipt = Path("/run/panel-renderer-sandbox")
    deadline = time.monotonic() + 15
    while not receipt.exists() and time.monotonic() < deadline:
        time.sleep(0.15)
    return (
        receipt.is_file()
        and receipt.stat().st_uid == 0
        and receipt.read_text().strip()
        == "BROWSER_SANDBOX seccomp=2 no_new_privs=1 pid_namespace=isolated"
    )


class ProbeServer(HTTPServer):
    def get_request(self):
        sock, peer = super().get_request()
        # Chromium may preconnect an unused loopback socket before navigating.
        sock.settimeout(3)
        return sock, peer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        page = (here / "page.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)
        print("BROWSER_PAGE loopback=1", flush=True)

    def do_POST(self):
        try:
            size = int(self.headers["Content-Length"])
            assert 0 < size < 2048
            data = json.loads(self.rfile.read(size))
            if self.path == "/rotate":
                rotation = data["rotation"]
                assert rotation in {"left", "right"}
                subprocess.run(
                    ["xrandr", "--output", "DSI-1", "--rotate", rotation], check=True
                )
                state = subprocess.check_output(["xrandr", "--current"], text=True)
                assert re.search(
                    r"^DSI-1 connected (?:primary )?2560x1600\+0\+0 " + rotation + " ",
                    state,
                    re.M,
                ), state
            elif self.path == "/sample":
                key = (data["lens"], data["rotation"])
                assert key in wanted and key not in self.server.cases
                ingested = data["corners"]
                assert sorted(ingested) == sorted("RGBY") and data["frames"] == 8, data
                end = time.monotonic() + 6
                while True:
                    visible = displayed()
                    if visible == ingested or time.monotonic() > end:
                        break
                    time.sleep(0.2)
                assert visible == ingested, (visible, ingested)
                self.server.cases[key] = visible
                print(
                    f"BROWSER_CHART lens={key[0]} crtc={key[1]} frames=8 "
                    f"size={data['width']}x{data['height']} video={ingested} presented={visible} expected={wanted[key]}",
                    flush=True,
                )
            elif self.path == "/done":
                self.server.finished = True
            else:
                raise RuntimeError(data)
        except Exception as e:
            self.server.failure = repr(e)
            self.send_error(500)
            return
        self.send_response(204)
        self.end_headers()


assert os.getuid() != 0 and os.environ["DISPLAY"] == ":22"
with (
    ProbeServer(("127.0.0.1", 0), Handler) as server,
    (work / "browser.log").open("w") as log,
):
    server.timeout = 0.5
    server.cases = {}
    server.finished = False
    server.failure = None
    app = subprocess.Popen(
        [
            "/usr/bin/chromium",
            "--ozone-platform=x11",
            "--user-data-dir=" + str(Path.home() / "profile"),
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--no-proxy-server",
            "--force-renderer-accessibility",
            "--force-device-scale-factor=1",
            "--window-size=820,640",
            "--app=http://127.0.0.1:" + str(server.server_port) + "/",
        ],
        stdout=log,
        stderr=log,
    )
    try:
        deadline = time.monotonic() + 380
        while (
            not server.finished
            and not server.failure
            and app.poll() is None
            and time.monotonic() < deadline
        ):
            server.handle_request()
        assert not server.failure and server.finished, (server.failure, app.poll())
        assert set(server.cases) == set(wanted) and sandboxed()
        assert set((work / "consent.log").read_text().splitlines()) >= {
            "BROWSER_CONSENT portal=1",
            "BROWSER_CONSENT site=1",
        }
        mismatches = sum(v != wanted[k] for k, v in server.cases.items())
        print(
            f"BROWSER_ORIENTATION_DONE cases=4 mismatches={mismatches} sandbox=1 portal=1 site=1",
            flush=True,
        )
    finally:
        app.terminate()
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
