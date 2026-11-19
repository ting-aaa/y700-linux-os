"""Exercise real Chromium WebGL 2 and check for the Y700's Adreno 730."""

import argparse
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
from queue import Empty, Full, Queue
import re
import secrets
import subprocess
import tempfile
from threading import Thread
import time


COLORS = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [0, 0, 0, 255]]
EXPECTED_SAMPLES = [COLORS, COLORS[1:] + COLORS[:1]]
SOFTWARE = re.compile(r"software|swiftshader|llvmpipe|lavapipe|softpipe|swrast|"
                      r"microsoft basic render|\bwarp\b", re.I)
ADRENO_730 = re.compile(r"\b(?:FD730|Adreno\s*(?:\(TM\)\s*|™\s*)?730)\b", re.I)
MESA_DRIVER = re.compile(r"\b(?:Mesa|Freedreno|Turnip)\b", re.I)


def verdict(report, frames, backend):
    if report.get("error"):
        return "webgl-error"
    if report.get("frames") != frames or report.get("samples") != EXPECTED_SAMPLES:
        return "readback-failed"
    vendor, renderer, version = (report.get(field) for field in ("vendor", "renderer", "version"))
    if not all(isinstance(value, str) and value.strip() for value in (vendor, renderer, version)):
        return "unmasked-renderer-unavailable"
    evidence = " ".join((vendor, renderer, version))
    if SOFTWARE.search(evidence):
        return "software-renderer"
    if not ADRENO_730.search(renderer):
        return "adreno-730-unproven"
    if not MESA_DRIVER.search(evidence):
        return "mesa-driver-unproven"
    if backend == "vulkan" and not re.search(r"\bVulkan\b", renderer, re.I):
        return "requested-backend-unproven"
    if backend in ("gl", "gles") and not re.search(r"\bOpenGL\b", renderer, re.I):
        return "requested-backend-unproven"
    return "adreno-730-rendered"


class ProbeHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, route, page, reports, **kwargs):
        self.route = route
        self.page = page
        self.reports = reports
        super().__init__(*args, **kwargs)

    def setup(self):
        self.request.settimeout(4)
        super().setup()

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.partition("?")[0] != self.route:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(self.page)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(self.page)

    def do_POST(self):
        if self.path != self.route:
            self.send_error(404)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if self.headers.get_content_type() != "application/json" or not 0 < size <= 16384:
                raise ValueError("Invalid report type or size")
            report = json.loads(self.rfile.read(size))
            if not isinstance(report, dict):
                raise ValueError("Expected a report object")
        except ValueError:
            self.send_error(400)
            return
        try:
            self.reports.put_nowait(report)
        except Full:
            self.send_error(409)
            return
        self.send_response(204)
        self.end_headers()


def run_browser(args):
    route = "/" + secrets.token_hex(16)
    reports = Queue(maxsize=1)
    page = Path(__file__).with_suffix(".html").read_bytes()
    handler = partial(ProbeHandler, route=route, page=page, reports=reports)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server, tempfile.TemporaryDirectory(
        prefix="y700-chromium-gpu-"
    ) as profile:
        url = f"http://127.0.0.1:{server.server_port}{route}?frames={args.frames}"
        command = [
            str(args.browser), f"--user-data-dir={profile}",
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
        ]
        if args.headless:
            command.append("--headless")
        elif platform.system() == "Linux":
            command.append("--ozone-platform=x11")
        if args.software_control:
            command.append("--disable-gpu")
        if args.backend != "default":
            command.extend(("--use-gl=angle", f"--use-angle={args.backend}"))
        command.append(url)

        Thread(target=server.serve_forever, daemon=True).start()
        try:
            browser = subprocess.Popen(command, stdout=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + args.timeout
                while time.monotonic() < deadline:
                    try:
                        return reports.get(timeout=0.25)
                    except Empty:
                        if browser.poll() is not None:
                            return {"error": f"Chromium exited with status {browser.returncode}"}
                return {"error": "Timed out waiting for the Chromium page report"}
            finally:
                if browser.poll() is None:
                    browser.terminate()
                    try:
                        browser.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        browser.kill()
                        browser.wait()
        finally:
            server.shutdown()


def self_test():
    valid = dict(frames=2, samples=EXPECTED_SAMPLES, vendor="Google Inc. (freedreno)",
                 renderer="ANGLE (freedreno, FD730, OpenGL ES 3.2 Mesa 25.0.7)", version="WebGL 2.0")
    turnip = "ANGLE (Qualcomm, Turnip Adreno (TM) 730, Vulkan 1.3.280)"
    cases = [
        ({}, "gles", "adreno-730-rendered"),
        ({"renderer": turnip, "vendor": "Google Inc. (Qualcomm)"}, "vulkan", "adreno-730-rendered"),
        ({"renderer": turnip}, "gl", "requested-backend-unproven"),
        ({"renderer": "FD7300"}, "default", "adreno-730-unproven"),
        ({"renderer": "ANGLE (Google, SwiftShader Device, Vulkan 1.3)"}, "default", "software-renderer"),
        ({"renderer": "FD730 via llvmpipe"}, "default", "software-renderer"),
        ({"renderer": "Adreno (TM) 730", "vendor": "Qualcomm"}, "default", "mesa-driver-unproven"),
        ({"renderer": None}, "default", "unmasked-renderer-unavailable"),
        ({"samples": [COLORS, COLORS]}, "default", "readback-failed"),
        ({"frames": 1}, "default", "readback-failed"),
        ({"error": "Context lost"}, "default", "webgl-error"),
    ]
    for changes, backend, expected in cases:
        actual = verdict(valid | changes, 2, backend)
        if actual != expected:
            raise AssertionError(f"{changes}: expected {expected}, got {actual}")
    print(f"Passed {len(cases)} renderer and readback decision cases.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", type=Path, default=Path("/usr/lib/chromium/chromium"),
                        help="Path to the native browser executable")
    parser.add_argument("--frames", type=int, default=120, help="Frames to verify, from 2 to 3600")
    parser.add_argument("--timeout", type=int, default=45, help="Maximum startup and workload seconds")
    parser.add_argument("--backend", choices=("default", "gl", "gles", "vulkan"), default="default")
    parser.add_argument("--headless", action="store_true", help="For PC validation without a desktop")
    parser.add_argument("--software-control", action="store_true", help="Negative control with --disable-gpu")
    parser.add_argument("--self-test", action="store_true", help="Check decisions without launching a browser")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not 2 <= args.frames <= 3600 or args.timeout < 1:
        parser.error("Choose 2–3600 frames and a positive timeout")
    if args.software_control and args.backend != "default":
        parser.error("Software control cannot select an ANGLE backend")
    if platform.system() == "Linux":
        if os.geteuid() == 0:
            parser.error("Run as an unprivileged user so Chromium can retain its sandbox")
        if not args.headless and not os.environ.get("DISPLAY"):
            parser.error("A signed-in X11 session with DISPLAY is required")
        if args.browser.resolve() == Path("/usr/bin/chromium"):
            parser.error("Select the native binary directly; the Debian wrapper applies product GPU defaults")
    try:
        report = run_browser(args)
    except OSError as error:
        report = {"error": str(error)}
    result = verdict(report, args.frames, args.backend)
    if args.software_control and result == "adreno-730-rendered":
        result = "software-control-unexpected-adreno"
    print(json.dumps({"result": result, "headless": args.headless, "kernel": platform.release(),
                      "backend": args.backend, "softwareControl": args.software_control,
                      "requestedFrames": args.frames, "report": report}, indent=2))
    return int(result != "adreno-730-rendered")


if __name__ == "__main__":
    raise SystemExit(main())
