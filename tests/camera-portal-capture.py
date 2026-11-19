"""Verify finite portal camera frames and independently witness their source.

Run from the desktop user's normal PipeWire and D-Bus session. The separate
pw-dump process observes graph metadata; only the portal FD enters the probe.
"""
import argparse
import codecs
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time


NODE = "PipeWire:Interface:Node"
LINK = "PipeWire:Interface:Link"
BYTES_PER_TWO_PIXELS = {
    "RGBx": 8, "RGBA": 8, "BGRx": 8, "BGRA": 8, "RGB": 6, "BGR": 6,
    "YUY2": 4, "UYVY": 4, "NV12": 3, "I420": 3,
}


class GraphMonitor:
    def __init__(self, pipe):
        self.fd = pipe.fileno()
        os.set_blocking(self.fd, False)
        self.utf8 = codecs.getincrementaldecoder("utf-8")()
        self.decoder = json.JSONDecoder()
        self.pending = ""
        self.events = []
        self.ready = False

    def read(self):
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except BlockingIOError:
                break
            if not chunk:
                raise RuntimeError("The graph monitor disconnected")
            self.pending += self.utf8.decode(chunk)
        self.pending = self.pending.lstrip()
        while self.pending:
            try:
                batch, end = self.decoder.raw_decode(self.pending)
            except json.JSONDecodeError:
                break   # The next read may complete the batch.
            self.pending = self.pending[end:].lstrip()
            for entry in batch:
                kind, info = entry.get("type"), entry.get("info", {})
                if info is None:
                    self.events.append((entry["id"], None, {}))
                elif kind == NODE:
                    props = info.get("props", {})
                    keys = ("node.name", "object.serial", "media.class", "media.role")
                    self.events.append((entry["id"], NODE, {k: props[k] for k in keys if k in props}))
                elif kind == LINK:
                    keys = ("input-node-id", "output-node-id", "state")
                    self.events.append((entry["id"], LINK, {k: info[k] for k in keys if k in info}))
            self.ready = True


def verified_link(events, stream_name, target, serial):
    # Look up the token first. A Link may be announced before the node's
    # name; both events belong to the same global ID until its removal.
    matches = [(i, obj) for i, (obj, kind, info) in enumerate(events)
               if kind == NODE and info.get("node.name") == stream_name]
    if not matches:
        return None
    first, stream = matches[0]
    if any(obj != stream for _, obj in matches):
        raise RuntimeError("Multiple stream nodes have the capture token")
    removals = [i for i, (obj, kind, _) in enumerate(events) if obj == stream and kind is None]
    start = max((i + 1 for i in removals if i < first), default=0)
    end = next((i for i in removals if i > first), None)
    if end is None:
        return None  # Require the complete lifetime, including disconnection.
    if matches[-1][0] > end:
        raise RuntimeError("Capture token was reused after its stream disconnected")

    source = {}
    links = {}
    active = None
    for i, (obj, kind, info) in enumerate(events[:end]):
        if kind is None:
            links.pop(obj, None)
            if obj == target:
                source.clear()
        elif kind == NODE and obj == target:
            source.update(info)
        elif kind == LINK:
            links.setdefault(obj, {}).update(info)
        if i < start:
            continue
        # Check after every individual event, including a Link immediately
        # withdrawn in the same JSON batch. Capture is invalid if any other
        # source was ever linked to this incarnation of the stream.
        for link_id, link in links.items():
            if link.get("input-node-id") != stream:
                continue
            if (link.get("output-node-id") != target or str(source.get("object.serial")) != serial or
                    source.get("media.class") != "Video/Source" or source.get("media.role") != "Camera"):
                raise RuntimeError("Capture stream linked to an unexpected source")
            if link.get("state") == "active":
                active = (target, stream, link_id)
    if not active:
        raise RuntimeError("Capture stream disconnected without a matching active Link")
    return active


def unsigned(fields, key, maximum):
    value = fields[key]
    if not value.isascii() or not value.isdecimal() or int(value) > maximum:
        raise ValueError(f"Invalid camera sample {key}")
    return int(value)


def sample_target(output, args, stream_name):
    samples = [line for line in output.splitlines() if line.startswith("CAMERA_SAMPLE ")]
    if len(samples) != 1:
        raise RuntimeError("Expected exactly one finite camera sample")
    pairs = [word.split("=", 1) for word in samples[0].split()[1:]]
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError("Duplicate fields in camera sample")
    if (fields["sensor"] != args.sensor or fields["serial"] != args.serial or
            fields["stream"] != stream_name or fields["size"] != "640x480" or
            unsigned(fields, "frames", 600) != args.frames or args.frames < 1):
        raise RuntimeError("Capture metadata does not match the request")
    bytes_per_pair = BYTES_PER_TWO_PIXELS.get(fields["format"])
    if bytes_per_pair is None:
        raise ValueError("Unexpected raw camera format")
    if unsigned(fields, "bytes", 2**64 - 1) < args.frames * 640 * 480 * bytes_per_pair // 2:
        raise ValueError("Insufficient payload for the negotiated camera format")
    unsigned(fields, "rejected", 2**32 - 1)
    return unsigned(fields, "target_node", 2**32 - 2)


def wait_for(graph, predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        graph.read()
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError("Timed out waiting for the PipeWire graph witness")


def run(args):
    token = secrets.token_hex(12)
    stream_name = f"y700.camera.probe.{token}"
    portal = Path(__file__).with_name("camera-portal-access.py")
    command = [sys.executable, str(portal), "--", args.probe, "--observer", token,
               args.sensor, args.serial, str(args.frames), str(args.seconds)]
    # A pipe keeps graph metadata in memory even if this process is killed.
    with subprocess.Popen(["pw-dump", "--monitor"], stdout=subprocess.PIPE) as monitor:
        try:
            graph = GraphMonitor(monitor.stdout)
            wait_for(graph, lambda: graph.ready)
            with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as proc:
                try:
                    while True:
                        graph.read()
                        try:
                            output, _ = proc.communicate(timeout=0.1)
                            break
                        except subprocess.TimeoutExpired:
                            continue
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                print(output, end="", flush=True)
                if proc.returncode:
                    raise RuntimeError(f"Camera portal client exited with status {proc.returncode}")
            target = sample_target(output, args, stream_name)
            output_id, input_id, link_id = wait_for(
                graph, lambda: verified_link(graph.events, stream_name, target, args.serial))
            print(f"PORTAL_CAMERA_OK sensor={args.sensor} serial={args.serial} frames={args.frames} "
                  f"source={output_id} stream={input_id} active_link={link_id}", flush=True)
        finally:
            monitor.terminate()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe")
    parser.add_argument("sensor", choices=("hi1339", "s5k4h7", "sc202cs"))
    parser.add_argument("serial")
    parser.add_argument("frames", type=int)
    parser.add_argument("seconds", type=int)
    try:
        run(parser.parse_args())
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        sys.exit(f"Camera portal witness: {exc}")
