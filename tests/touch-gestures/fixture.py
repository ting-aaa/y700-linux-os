"""Loopback-only browser fixture and assertions for direct-touch gestures."""

import fcntl
import json
import os
import secrets
import socket
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


# Screen positions fixed independently from the C fixture's native-axis samples
# and the XInput transformation chosen by the guest.
TAP_TARGETS = {
    "normal": (0.245, 0.660),
    "left": (0.340, 0.245),
    "inverted": (0.755, 0.340),
    "right": (0.660, 0.755),
}
GESTURE_STARTS = {
    "scroll": ((0.34, 0.73), (0.48, 0.73)),
    "pinch": ((0.48, 0.47), (0.66, 0.47)),
}


class Fixture(BaseHTTPRequestHandler):
    latest = b"{}"
    page = Path(__file__).with_name("fixture.html").read_bytes()

    def respond(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if urlsplit(self.path).path == "/":
            self.respond(self.page, "text/html; charset=utf-8")
        elif self.path == "/record":
            self.respond(type(self).latest, "application/json")
        else:
            self.send_error(404)

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if self.path != "/record" or not 0 < size < 8192:
            self.send_error(400)
            return
        type(self).latest = self.rfile.read(size)
        self.respond(b"OK", "text/plain")

    def log_message(self, *_):
        pass


def check_position(actual, expected):
    assert abs(actual["x"] - expected[0]) < 0.02, actual
    assert abs(actual["y"] - expected[1]) < 0.02, actual


def verify(record, phase, rotation, width, height, factor):
    viewport = record["viewport"]
    assert record["rotation"] == rotation, record
    assert viewport["dpr"] == factor, viewport
    assert (viewport["width"] * factor, viewport["height"] * factor) == (width, height), viewport
    if phase == "ready":
        assert record["visible"] == "visible" and record["focused"], record
        assert record["loaded"] == "complete" and record["frames"] >= 8, record
        assert record["touches"] == 0 and not record["gestures"], record
        assert not record["taps"] and not record["clicks"], record
        assert viewport["scroll"] == 0 and viewport["scale"] == 1, record
        return

    assert len(record["taps"]) == 1, record
    tap = record["taps"][0]
    assert tap["target"] == rotation and tap["trusted"], record
    check_position(tap, TAP_TARGETS[rotation])
    assert record["clicks"] == [{"target": rotation, "trusted": True, "touch": True}], record
    if phase == "tap":
        assert record["touches"] == 1 and not record["gestures"], record
        assert viewport["scroll"] == 0 and viewport["scale"] == 1, record
        return

    number = 1 if phase == "scroll" else 2
    assert record["touches"] == 1 + 2 * number and len(record["gestures"]) == number, record
    before = record["gestures"][-1]
    start = before["before"]
    assert len(before["points"]) == 2 and before["trusted"] and start["scale"] == 1, record
    for contact, expected in zip(sorted(before["points"], key=lambda point: point["x"]),
                                 GESTURE_STARTS[phase], strict=True):
        check_position(contact, expected)
    if phase == "scroll":
        assert viewport["scroll"] - start["scroll"] > 80 and viewport["scale"] == 1, record
    elif phase == "pinch":
        assert viewport["scale"] >= 1.25 and viewport["dpr"] == start["dpr"], record
        assert abs(viewport["scroll"] - start["scroll"]) <= 2, record


def verify_axes(device):
    # Linux EVIOCGABS and struct input_absinfo. These are kernel-reported
    # ranges of the guest evdev device that libinput will actually open.
    axes = {0x00: 16000, 0x01: 25600, 0x2F: 9, 0x35: 16000, 0x36: 25600}
    with open(device, "rb", buffering=0) as evdev:
        for axis, maximum in axes.items():
            request = (2 << 30) | (24 << 16) | (ord("E") << 8) | (0x40 + axis)
            _, low, high, *_ = struct.unpack("6i", fcntl.ioctl(evdev, request, bytes(24)))
            assert (low, high) == (0, maximum), (axis, low, high)
    print("TOUCH_AXES abs_x=0..16000 abs_y=0..25600 mt_x=0..16000 mt_y=0..25600 slots=10")


def write_xauthority(filename, display):
    # Xauthority FamilyLocal, using Xau's length-prefixed record format.
    fields = (socket.gethostname().encode(), display.encode(), b"MIT-MAGIC-COOKIE-1", secrets.token_bytes(16))
    with os.fdopen(os.open(filename, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb") as authority:
        authority.write(struct.pack("!H", 256))
        for field in fields:
            authority.write(struct.pack("!H", len(field)))
            authority.write(field)


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        ThreadingHTTPServer(("127.0.0.1", 8937), Fixture).serve_forever()
    elif sys.argv[1] == "xauthority":
        write_xauthority(*sys.argv[2:])
    elif sys.argv[1] == "axes":
        verify_axes(sys.argv[2])
    else:
        mode, rotation, width, height, factor = sys.argv[1:]
        verify(json.load(sys.stdin), mode, rotation, int(width), int(height), int(factor))
