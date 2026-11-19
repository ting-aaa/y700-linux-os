"""Exclusively verify the fixed F15 and (+1, -1) report from the supervised BLE peer."""
import argparse
import contextlib
import errno
import fcntl
import os
from pathlib import Path
import re
import select
import signal
import stat
import struct
import time

KEY_F15 = 185
EV_KEY, EV_REL = 1, 2
BUS_BLUETOOTH = 5
EVIOCGRAB = 0x40044590
EVENT = struct.Struct("@llHHi")
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC


def address(text):
    if re.fullmatch(r"(?:[0-9A-Fa-f]{12}|(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})", text):
        return text.replace(":", "").upper()
    return None


def alternate(directory, started):
    try:
        fd = os.open("peer-address", os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_mode & 0o077
                or not started <= meta.st_mtime_ns <= time.time_ns()):
            return None
        value = stream.read(19)
        if len(value) > 18:
            return None
        return address(value.removesuffix(b"\n").decode("ascii", errors="replace"))


def query(fd, nr, size):
    data = bytearray(size)
    fcntl.ioctl(fd, 0x80004500 | (size << 16) | nr, data)
    return data


def candidate(node, peers, stack):
    sysdev = node / "device"
    if (sysdev / "id/bustype").read_text().strip() != "0005":
        return None
    peer = address((sysdev / "uniq").read_text().strip())
    if peer not in peers:
        return None
    fd = os.open("/dev/input/" + node.name, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW)
    stack.callback(os.close, fd)
    opened = os.fstat(fd)
    major, minor = map(int, (node / "dev").read_text().split(":"))
    if not stat.S_ISCHR(opened.st_mode) or opened.st_rdev != os.makedev(major, minor):
        return None
    bus, _, _, _ = struct.unpack("@4H", query(fd, 0x02, 8))
    uniq = query(fd, 0x08, 128).split(b"\0", 1)[0].decode("ascii", errors="replace")
    if bus != BUS_BLUETOOTH or address(uniq) != peer:
        return None
    # Require the Windows fixture's narrow capabilities. It declares only F15
    # on the keyboard and only REL_X, REL_Y on the pointer.
    keys = int.from_bytes(query(fd, 0x20 + EV_KEY, 96), "little")
    rel = int.from_bytes(query(fd, 0x20 + EV_REL, 8), "little")
    if keys not in (0, 1 << KEY_F15) or rel not in (0, 3):
        return None
    return peer, fd, bool(keys), bool(rel)


def unique_pair(candidates):
    keys = [(p, fd) for p, fd, key, _ in candidates if key]
    mice = [(p, fd) for p, fd, _, mouse in candidates if mouse]
    if len(keys) == len(mice) == 1 and keys[0][0] == mice[0][0]:
        return keys[0][1], mice[0][1]
    return None


class Reports:
    def __init__(self, key, mouse):
        self.key, self.mouse = key, mouse
        self.key_state = 0
        self.movement = {}
        self.mouse_done = False

    def event(self, fd, typ, code, value):
        if typ == 0 and code == 3:
            raise RuntimeError("Input stream desynchronized")
        if fd == self.key and typ == EV_KEY and code == KEY_F15:
            if self.key_state == 0 and value == 1:
                self.key_state = 1
            elif self.key_state == 1 and value == 0:
                self.key_state = 2
        if fd == self.mouse:
            if typ == EV_REL and code in (0, 1):
                self.movement[code] = value
            elif typ == 0 and code == 0:
                self.mouse_done |= self.movement == {0: 1, 1: -1}
                self.movement.clear()

    def done(self):
        return self.key_state == 2 and self.mouse_done


def mark(directory, name):
    fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | NOFOLLOW, 0o600, dir_fd=directory)
    with os.fdopen(fd, "wb") as stream:
        stream.write(b"1\n")


def read_events(pair, directory, deadline):
    fds = set(pair)
    for fd in fds:
        fcntl.ioctl(fd, EVIOCGRAB, 1)
    for fd in fds:
        while time.monotonic() < deadline:
            try:
                if not os.read(fd, EVENT.size * 64):
                    raise RuntimeError("Input device disconnected")
            except BlockingIOError:
                break
    if time.monotonic() >= deadline:
        raise TimeoutError("Input queue did not settle")
    mark(directory, "input-ready")
    try:
        print("TABLET_INPUT_READY", flush=True)
        reports = Reports(*pair)
        while not reports.done():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Fixed input was not verified")
            for fd in select.select(list(fds), [], [], min(remaining, .5))[0]:
                data = os.read(fd, EVENT.size * 64)
                if not data:
                    raise RuntimeError("Input device disconnected")
                for _, _, typ, code, value in EVENT.iter_unpack(data):
                    reports.event(fd, typ, code, value)
        mark(directory, "input-done")
        print("F15_PRESS_RELEASE_AND_RELATIVE_XY_VERIFIED", flush=True)
    finally:
        os.unlink("input-ready", dir_fd=directory)


def capture(runtime, host, timeout):
    if (os.geteuid() != 0 or runtime.parent != Path("/run")
            or not re.fullmatch(r"y700-[A-Za-z0-9_.-]+", runtime.name)):
        raise RuntimeError("Expected the supervised private /run/y700-* directory")
    started = time.time_ns()
    deadline = time.monotonic() + timeout
    with contextlib.ExitStack() as run:
        directory = os.open(runtime, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
        run.callback(os.close, directory)
        meta = os.fstat(directory)
        if meta.st_uid != 0 or meta.st_mode & 0o077:
            raise RuntimeError("Expected a private root-owned run")
        lock = os.open("capture-lock", os.O_RDWR | os.O_CREAT | os.O_EXCL | NOFOLLOW,
                       0o600, dir_fd=directory)
        run.callback(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if set(os.listdir(directory)) & {"input-ready", "input-done"}:
            raise RuntimeError("Input marker already exists")
        while time.monotonic() < deadline:
            observed = alternate(directory, started)
            if not observed:
                time.sleep(.15)
                continue
            peers = {host, observed}
            with contextlib.ExitStack() as devices:
                selected = []
                for node in Path("/sys/class/input").glob("event[0-9]*"):
                    try:
                        result = candidate(node, peers, devices)
                    except OSError as e:
                        if e.errno not in (errno.ENOENT, errno.ENODEV, errno.ENXIO):
                            raise
                        continue
                    if result:
                        selected.append(result)
                pair = unique_pair(selected)
                if pair:
                    read_events(pair, directory, deadline)
                    return
            time.sleep(.15)
    raise TimeoutError("No unique matching Bluetooth input pair")


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--runtime", required=True, type=Path)
    cli.add_argument("--host-address", required=True)
    cli.add_argument("--timeout", type=int, default=120)
    options = cli.parse_args()
    if not re.fullmatch(r"[0-9A-Fa-f]{12}", options.host_address) or not 1 <= options.timeout <= 300:
        cli.error("Expected a 12-hex-digit host address and timeout of 1–300 seconds")
    def interrupted(signum, frame):
        raise InterruptedError("Input capture interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        capture(options.runtime, options.host_address.upper(), options.timeout)
    except (OSError, RuntimeError) as error:
        raise SystemExit(str(error)) from None
