"""Loopback-only browser fixture and assertions for direct-touch gestures."""

import json
import os
import secrets
import socket
import struct
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


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
        if self.path == "/":
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


def verify(record, phase, width, height):
    viewport = record["viewport"]
    assert (viewport["width"], viewport["height"]) == (width, height), viewport
    if phase == "ready":
        assert not record["gestures"] and viewport["scroll"] == 0 and viewport["scale"] == 1, record
        return
    number = 1 if phase == "scroll" else 2
    assert len(record["gestures"]) == number, record
    before = record["gestures"][-1]
    start = before["before"]
    assert before["contacts"] == 2 and start["scale"] == 1, record
    assert abs(before["x"] - 0.5) < 0.06, record
    assert abs(before["y"] - (0.73 if phase == "scroll" else 0.47)) < 0.07, record
    if phase == "scroll":
        assert viewport["scroll"] - start["scroll"] > 80 and viewport["scale"] == 1, record
    elif phase == "pinch":
        assert viewport["scale"] >= 1.25 and viewport["dpr"] == start["dpr"], record
    else:
        raise ValueError(phase)


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
        HTTPServer(("127.0.0.1", 8937), Fixture).serve_forever()
    elif sys.argv[1] == "xauthority":
        write_xauthority(*sys.argv[2:])
    else:
        mode, width, height = sys.argv[1:]
        verify(json.load(sys.stdin), mode, int(width), int(height))
