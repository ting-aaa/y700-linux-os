"""Drive the throwaway EFI guest over its private boot, touch and QMP sockets."""

import json
import os
from pathlib import Path
import secrets
import socket
import sys
import time


ENROLL = {
    "a": (59, 556), "b": (613, 638), "c": (408, 638), "d": (286, 556),
    "e": (256, 477), "f": (399, 556), "s": (171, 556), "y": (562, 477),
}
GREETER = {
    "a": (150, 668), "b": (437, 707), "c": (313, 707), "d": (275, 668),
    "e": (260, 630), "f": (336, 668), "s": (212, 668), "y": (446, 630),
    "0": (653, 592), "7": (468, 592),
}
SCREEN_WIDTH = 1024
SCREEN_HEIGHT = 768


def connect(work, name, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(work / name))
            sock.settimeout(40)
            return sock
        except (FileNotFoundError, ConnectionRefusedError):
            sock.close()
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def boot(work):
    with connect(work, "serial.sock") as serial:
        recent = b""
        interrupted = False
        while b"=> " not in recent:
            block = serial.recv(65536)
            if not block:
                raise RuntimeError("Serial disconnected before U-Boot prompt")
            recent = (recent + block)[-65536:]
            if not interrupted and b"autoboot" in recent.lower():
                serial.sendall(b"\r")
                interrupted = True
        serial.sendall(
            b"virtio scan; if part number virtio 0 linux-boot bootpart; then "
            b"if fatload virtio 0:${bootpart} ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; "
            b"then bootefi ${kernel_addr_r}; fi; fi\r"
        )
        recent = b""
        while b"Booting /" not in recent:
            block = serial.recv(65536)
            if not block:
                raise RuntimeError("Serial disconnected before the EFI loader booted Linux")
            recent = (recent + block)[-65536:]
    print("COMBINED_HOST_UBOOT_EFI", flush=True)


def wait_marker(work, marker, budget):
    deadline = time.monotonic() + budget
    while time.monotonic() < deadline:
        report = (work / "report.log").read_text(errors="replace").splitlines()
        if any(line.startswith("COMBINED_FAIL ") for line in report):
            raise RuntimeError("Guest observer reported a failure")
        if marker in report:
            print(marker, flush=True)
            return
        time.sleep(0.35)
    raise TimeoutError(marker)


def panel(work):
    frame = work / "frame.raw"
    try:
        with connect(work, "qmp.sock") as sock, sock.makefile("rwb") as stream:
            if "QMP" not in json.loads(stream.readline()):
                raise RuntimeError("Unexpected QMP greeting")
            for request in (
                {"execute": "qmp_capabilities"},
                {"execute": "pmemsave", "arguments": {"val": 0xBE000000,
                 "size": SCREEN_WIDTH * SCREEN_HEIGHT * 4, "filename": str(frame)}},
            ):
                stream.write(json.dumps(request).encode("ascii") + b"\n")
                stream.flush()
                while True:
                    reply = json.loads(stream.readline())
                    if "error" in reply:
                        raise RuntimeError("QMP could not read the synthetic display")
                    if "return" in reply:
                        break
        return frame.read_bytes()
    finally:
        frame.unlink(missing_ok=True)


def greeter_ready(work, name):
    references = json.loads(Path(__file__).with_name("greeter-pixels.json").read_text())
    deadline = time.monotonic() + 145
    while time.monotonic() < deadline:
        data = panel(work)

        def match(region):
            bounds, threshold, expected = references[region]
            left, top, right, bottom = bounds
            observed = []
            for y in range(top, bottom):
                for x in range(left, right):
                    index = (y * SCREEN_WIDTH + x) * 4
                    observed.append(sum(data[index:index + 3]) > threshold)
            return sum(value != (expected[i] == "1") for i, value in enumerate(observed)) <= 12

        if match("keyboard") and match(name) and match("login") == (name == "username"):
            print(f"COMBINED_GREETER_RENDERED prompt={name} onscreen_keyboard=1", flush=True)
            return
        time.sleep(0.6)
    raise TimeoutError(f"Arctica did not render the {name} keyboard prompt")


def enter(stream, keymap, word, submit):
    for x, y in [*(keymap[letter] for letter in word), submit]:
        stream.write(f"tap {x} {y}\n".encode("ascii"))
        stream.flush()
        reply = stream.readline().strip()
        if reply == b"READY":
            reply = stream.readline().strip()
        if reply != b"OK":
            raise RuntimeError("Guest touch endpoint did not acknowledge the tap")
    time.sleep(3)


def make_secret():
    alphabet = sorted(ENROLL.keys() & GREETER.keys())
    return "".join(secrets.choice(alphabet) for _ in range(12))


def tap_reported_control(work, stream, marker):
    deadline = time.monotonic() + 420
    while time.monotonic() < deadline:
        report = (work / "report.log").read_text(errors="replace").splitlines()
        if any(line.startswith("COMBINED_FAIL ") for line in report):
            raise RuntimeError(f"Guest observer failed before {marker}")
        button = next((line for line in report if line.startswith(marker + " ")), None)
        if button:
            _, sx, sy = button.split()
            x, y = int(sx), int(sy)
            if not (0 <= x < SCREEN_WIDTH and 0 <= y < SCREEN_HEIGHT):
                raise ValueError(f"{marker} is outside the guest display")
            enter(stream, {}, "", (x, y))
            return
        time.sleep(0.35)
    raise TimeoutError(marker)


def exercise(work, secret, cold=False):
    boot(work)
    if cold:
        wait_marker(work, "COMBINED_COLD_GREETER enrollment_skipped=1 account=configured", 260)
    else:
        wait_marker(work, "COMBINED_FIRSTBOOT_READY", 240)
        time.sleep(4)
    with connect(work, "touch.sock") as sock, sock.makefile("rwb") as stream:
        if not cold:
            other = ("s" if secret[0] == "a" else "a") + secret[1:]
            enter(stream, ENROLL, secret, (940, 723))
            enter(stream, ENROLL, other, (940, 723))
            wait_marker(work, "COMBINED_MISMATCH_STILL_LOCKED", 100)
            time.sleep(3)
            enter(stream, ENROLL, secret, (940, 723))
            enter(stream, ENROLL, secret, (940, 723))
            wait_marker(work, "COMBINED_MATCH_GREETER", 220)
        greeter_ready(work, "username")
        enter(stream, GREETER, "y700", (894, 648))
        greeter_ready(work, "password")
        enter(stream, GREETER, secret, (894, 648))
        wait_marker(work, "COMBINED_PAM_XFCE account=y700 ordinary=1 active=1 local=1 seat=seat0 type=x11", 320)
        if os.environ.get("SCREEN_LOCK") in ("candidate", "installed"):
            sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "screen-lock"))
            from drive_lock import unlock
            unlock(work, stream, secret)
        edition = os.environ.get("MEDIA_EDITION")
        if edition in ("dev12.12", "dev12.13"):
            tap_reported_control(work, stream, "COMBINED_GPU_ON_BUTTON")
            tap_reported_control(work, stream, "COMBINED_GPU_OFF_BUTTON")
        if edition == "dev12.13":
            for marker in ("TRAY", "ON", "OFF", "CLOSE"):
                tap_reported_control(work, stream, f"COMBINED_QUICK_{marker}_BUTTON")
        if edition in ("dev12.11", "dev12.12", "dev12.13"):
            tap_reported_control(work, stream, "COMBINED_CAMERA_BUTTON")
        wait_marker(work, "COMBINED_PASS", 420)


if __name__ == "__main__":
    exercise(Path(sys.argv[1]).resolve(), make_secret())
