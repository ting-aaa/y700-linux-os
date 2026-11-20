"""Run only in the marked virt guest after BlueZ attaches the exported WinRT report map."""
from contextlib import nullcontext
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

from central import EVENT, control, desktop_observer, inputs_for, wait


def xorg_legacy_nodes(nodes):
    log = Path("/run/Xorg.log").read_text().splitlines()
    if not all(any("config/udev: Adding input device" in line and f"(/dev/input/{node})" in line
                   for line in log) for node in nodes):
        return False
    ids = subprocess.check_output(["xinput", "--list", "--id-only"], text=True).split()
    properties = [subprocess.check_output(["xinput", "list-props", device], text=True) for device in ids]
    return {node for node in nodes if any(f'"/dev/input/{node}"' in props for props in properties)}


def captured(address):
    with tempfile.TemporaryDirectory(dir="/run", prefix="y700-report-") as tmp:
        runtime = Path(tmp)
        args = [sys.executable, "-B", "capture-input.py", "--runtime", tmp,
                "--host-address", address.replace(":", ""), "--timeout", "15"]
        with subprocess.Popen(args) as process:
            try:
                wait("WINDOWS_CAPTURE_STARTED", lambda: (runtime / "capture-lock").exists(), 5)
                peer = runtime / "peer-address"
                fd = os.open(peer, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, "w") as stream:
                    stream.write(address + "\n")
                wait("WINDOWS_EXCLUSIVE_GRAB_ARMED", lambda: (runtime / "input-ready").exists(), 8)
                assert control(b"emit")
                assert process.wait(timeout=6) == 0 and (runtime / "input-done").is_file()
            finally:
                if process.poll() is None:
                    process.terminate()


def check(address):
    cmdline = Path("/proc/cmdline").read_text().split()
    assert "y700.windows_report=1" in cmdline and os.environ["Y700_GTK_HID"] == "1"
    expect_mouse = "y700.legacy_mouse=1" not in cmdline
    motion = Path("motion.bin").read_bytes()
    assert motion == (bytes([0, 1, 255]) if expect_mouse else bytes([1, 255]))

    def report_nodes():
        nodes = list(inputs_for(address))
        if len(nodes) == 2:
            for node in nodes:
                dev = Path("/sys/class/input", node, "dev").read_text().strip()
                if not Path("/run/udev/data", "c" + dev).is_file():
                    return None
            return nodes

    nodes = wait("WINDOWS_TWO_REPORT_NODES", report_nodes)
    mice = 0
    keyboards = set()
    for node in nodes:
        result = subprocess.check_output(["udevadm", "info", "-q", "property", "-n", "/dev/input/" + node], text=True)
        mice += "ID_INPUT_MOUSE=1" in result.splitlines()
        if "ID_INPUT_KEY=1" in result.splitlines():
            keyboards.add(node)
    assert mice == int(expect_mouse), f"Expected {int(expect_mouse)} mouse tags, found {mice}"
    if expect_mouse:
        captured(address)
    else:
        accepted = wait("WINDOWS_LEGACY_XORG_NODES", lambda: xorg_legacy_nodes(nodes))
        assert len(keyboards) == 1 and accepted == keyboards, (accepted, keyboards)
        print("LEGACY_XINPUT keyboard=1 pointer=0", flush=True)
    witness = desktop_observer(address, None) if expect_mouse else nullcontext()
    with witness:
        fds = []
        try:
            for node in nodes:
                fds.append(os.open("/dev/input/" + node, os.O_RDONLY | os.O_NONBLOCK))
            assert control(b"emit")
            seen = []
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and len(seen) < 4:
                for fd in select.select(fds, [], [], .2)[0]:
                    seen.extend((typ, code, value) for _, _, typ, code, value in EVENT.iter_unpack(os.read(fd, EVENT.size * 64))
                                if typ in (1, 2))
            assert sorted(seen) == sorted([(1, 185, 1), (1, 185, 0), (2, 0, 1), (2, 1, -1)])
            assert seen.index((1, 185, 1)) < seen.index((1, 185, 0))
        finally:
            for fd in fds:
                os.close(fd)
    print(f"WINRT_REPORT evdev_fixed=1 mouse_tag={mice} gtk_observed={int(expect_mouse)} button_events=0", flush=True)
