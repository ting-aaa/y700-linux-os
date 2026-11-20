"""Start an isolated 512-MiB ARM64 guest with two disposable writable disk files."""
from pathlib import Path
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import time

work, logs, kernel, initrd = [Path(arg).resolve() for arg in sys.argv[1:5]]
qemu = sys.argv[5:]


def canary(name):
    path = work / f"{name}.img"
    with path.open("xb") as f:
        f.truncate(4 * 1024 * 1024)
        f.seek(446)
        f.write(struct.pack("<B3sB3sII", 0, bytes(3), 0x83, bytes(3), 2048, 4096))
        f.seek(510)
        f.write(b"\x55\xaa")
        f.seek(1048576)
        f.write(os.urandom(32768))
    return path, hashlib.sha256(path.read_bytes()).hexdigest()


def qmp_hotplug():
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(str(work / "qmp.sock"))
        with sock.makefile("rwb") as stream:
            assert "QMP" in json.loads(stream.readline())
            for command in ({"execute": "qmp_capabilities"},
                            {"execute": "device_add", "arguments": {"driver": "usb-storage",
                             "drive": "hot", "bus": "xhci.0", "id": "hot-canary"}}):
                stream.write(json.dumps(command).encode() + b"\n")
                stream.flush()
                while True:
                    reply = json.loads(stream.readline())
                    if "error" in reply:
                        raise RuntimeError(reply)
                    if "return" in reply:
                        break


cold, cold_hash = canary("cold")
hot, hot_hash = canary("hot")
print(f"MEDIA_HOST_ORIGINAL vda={cold_hash} sda={hot_hash}", flush=True)
data = os.environ.get("QEMU_DATA")
args = [*qemu, *(["-L", data] if data else []), "-machine", "virt,gic-version=3", "-cpu", "max",
        "-smp", "2", "-m", "512", "-nodefaults", "-no-user-config", "-display", "none", "-nic", "none",
        "-no-reboot", "-monitor", "none", "-serial", f"file:{logs}/serial.log",
        "-qmp", "unix:qmp.sock,server=on,wait=off", "-kernel", str(kernel), "-initrd", str(initrd),
        "-append", "console=ttyAMA0 rdinit=/qa-init panic=-1", "-device", "qemu-xhci,id=xhci",
        "-drive", f"if=none,format=raw,file={cold},id=cold,readonly=off",
        "-device", "virtio-blk-device,drive=cold",
        "-drive", f"if=none,format=raw,file={hot},id=hot,readonly=off"]
with (logs / "qemu.log").open("xb") as out:
    guest = subprocess.Popen(args, cwd=work, stdin=subprocess.DEVNULL, stdout=out, stderr=out)
    try:
        deadline = time.monotonic() + 150
        added = False
        serial = logs / "serial.log"
        while guest.poll() is None and time.monotonic() < deadline:
            if not added and serial.exists() and "MEDIA_REQUEST_HOT" in serial.read_text(errors="replace"):
                qmp_hotplug()
                added = True
            time.sleep(0.25)
        if guest.poll() != 0:
            raise RuntimeError("QEMU media fixture failed or timed out")
    finally:
        if guest.poll() is None:
            guest.kill()
            guest.wait()
lines = serial.read_text(errors="replace").splitlines()
for line in lines:
    if line.startswith("MEDIA_"):
        print(line)
for path, digest, device in ((cold, cold_hash, "vda"), (hot, hot_hash, "sda")):
    observed = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"MEDIA_HOST_CANARY device={device} qemu_readonly=off final_sha256={observed}", flush=True)
    if observed != digest:
        raise RuntimeError(f"Disposable {device} changed from {digest} to {observed}")
    if f"{digest}  /dev/{device}" not in lines:
        raise RuntimeError(f"Missing guest checksum for {device}")
if not (added and "MEDIA_PASS" in lines) or any("MEDIA_FAIL" in line for line in lines):
    raise RuntimeError("The guest could not verify the cold and hot canaries")
