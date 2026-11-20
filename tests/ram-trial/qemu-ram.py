"""Verify the sealed RAM boot using only private virtio serial ports and QMP."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "combined-efi"))
import drive


def wait_for_marker(log, guest, expected, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        lines = log.read_text(errors="replace").splitlines()
        if any(line.startswith("COMBINED_FAIL ") for line in lines):
            try:
                guest.wait(60)
            except subprocess.TimeoutExpired:
                pass
            raise RuntimeError("RAM guest observer reported a failure")
        if expected in lines:
            print(expected, flush=True)
            return
        if guest.poll() is not None:
            last = next((line.split()[0] for line in reversed(lines) if line.startswith(("COMBINED_", "RAM_TRIAL_"))), "none")
            raise RuntimeError(f"Guest exited before {expected.split()[0]}, last stage {last}")
        time.sleep(0.8)
    raise TimeoutError(expected.split()[0])


class GuestBootPanic(RuntimeError):
    pass


def check_boot_panic(serial):
    try:
        data = serial.read_bytes()
    except FileNotFoundError:
        return
    match = re.search(rb"(?m)^(?:\[ *[0-9]+\.[0-9]+\] *)?Kernel panic - not syncing:[^\r\n]*[\r\n]", data)
    if match:
        reason = match[0].strip().decode("utf-8", errors="replace")
        raise GuestBootPanic(f"Guest kernel panicked before the switched-root observer: {reason}")


def retain_initrd_prefix(work, logs, expected_bytes):
    serial = (logs / "serial.log").read_bytes()
    loader, handover, next_boot = serial.partition(b"RAM_QA_KEXEC_HANDOVER")
    if not handover or b"Initramfs unpacking failed:" not in next_boot:
        raise RuntimeError("Missing second-kernel initramfs failure witness")
    segments = re.findall(rb"Loaded initrd at 0x([0-9a-f]+) bufsz=0x([0-9a-f]+) memsz=0x([0-9a-f]+)", loader)
    if len(segments) != 1:
        raise RuntimeError("Missing or ambiguous kexec initrd destination")
    start, size, reserved = (int(value, 16) for value in segments[0])
    if size != expected_bytes or not (size <= reserved < size + 65536):
        raise RuntimeError("kexec destination length differs from the sealed initrd")
    if not 0x40000000 <= start < start + size <= 0x280000000:
        raise RuntimeError("kexec initrd lies outside the virtual RAM bank")
    count = min(12 * 1024 * 1024, size)
    if start < 0xbe300000 and start + count > 0xbe000000:
        count = 0xbe000000 - start
    if count <= 0:
        raise RuntimeError("kexec initrd prefix intersects the framebuffer")
    output = logs / "initrd-prefix.bin"
    if output.exists() or output.is_symlink():
        raise RuntimeError("Refusing to replace an existing prefix capture")
    with drive.connect(work, "qmp.sock") as sock, sock.makefile("rwb") as stream:
        sock.settimeout(15)
        if "QMP" not in json.loads(stream.readline()):
            raise RuntimeError("Unexpected QMP greeting")
        for command in (
            {"execute": "qmp_capabilities"},
            {"execute": "pmemsave", "arguments": {"val": start, "size": count, "filename": str(output)}},
        ):
            stream.write(json.dumps(command).encode("ascii") + b"\n")
            stream.flush()
            while True:
                reply = json.loads(stream.readline())
                if "error" in reply:
                    raise RuntimeError("QMP rejected the scoped initrd capture")
                if "return" in reply:
                    break
    if output.stat().st_size != count:
        raise RuntimeError("QMP wrote an incomplete initrd prefix")
    print(f"RAM_TRIAL_PANIC_INITRD_PREFIX addr=0x{start:x} bytes={count} file={output.name}", flush=True)


def send_observer(work, logs, guest):
    with drive.connect(work, "qa-seed.sock") as seed:
        seed.settimeout(1)
        ready = bytearray()
        deadline = time.monotonic() + (650 if os.getenv("RAM_TRIAL_KEXEC") == "1" else 420)
        serial = logs / "serial.log"
        while b"\n" not in ready and time.monotonic() < deadline:
            check_boot_panic(serial)
            try:
                packet = seed.recv(64)
            except TimeoutError:
                if guest.poll() is not None:
                    raise RuntimeError("Guest exited before switched-root observer startup")
                continue
            if not packet:
                check_boot_panic(serial)
                break
            ready.extend(packet)
            if len(ready) > 32:
                break
        if ready != b"RAM_QA_READY\n":
            raise RuntimeError("Missing switched-root QA handshake")
        seed.settimeout(45)
        seed.sendall((work / "qa.tar").read_bytes())
    print("RAM_TRIAL_QA_SEEDED transport=virtio-serial", flush=True)


def greeter_ready(work, prompt):
    try:
        drive.greeter_ready(work, prompt)
    except TimeoutError as exc:
        if exc.args != (f"Arctica did not render the {prompt} keyboard prompt",):
            raise
        drive.greeter_ready(work, prompt)


def touch_only(work, logs, guest):
    report = logs / "report.log"
    secret = drive.make_secret()
    mismatch = ("s" if secret[0] == "a" else "a") + secret[1:]
    with drive.connect(work, "login-phase.sock") as stage:
        wait_for_marker(report, guest, "COMBINED_FIRSTBOOT_READY", 240)
        time.sleep(4)
        with drive.connect(work, "touch.sock") as touch, touch.makefile("rwb") as stream:
            drive.enter(stream, drive.ENROLL, secret, (940, 723))
            drive.enter(stream, drive.ENROLL, mismatch, (940, 723))
            wait_for_marker(report, guest, "COMBINED_MISMATCH_STILL_LOCKED", 100)
            time.sleep(3)
            drive.enter(stream, drive.ENROLL, secret, (940, 723))
            drive.enter(stream, drive.ENROLL, secret, (940, 723))
            wait_for_marker(report, guest, "COMBINED_MATCH_GREETER", 330)
            greeter_ready(work, "username")
            drive.enter(stream, drive.GREETER, "y700", (894, 648))
            greeter_ready(work, "password")
            drive.enter(stream, drive.GREETER, secret, (894, 648))
            stage.sendall(b"LOGIN_SUBMITTED\n")
            wait_for_marker(report, guest, "FILE_TRIAL_TOUCH_SUBMITTED acknowledged=1", 30)
            wait_for_marker(report, guest, "COMBINED_PAM_XFCE account=y700 ordinary=1 active=1 local=1 seat=seat0 type=x11", 455)
            if os.getenv("RAM_TRIAL_SLEEP") == "1":
                # The virtio-serial ports reset during suspend. The PL011
                # console carries the guest's post-resume verdict.
                wait_for_marker(logs / "serial.log", guest, "RAM_TRIAL_PASS", 240)
            else:
                wait_for_marker(report, guest, "RAM_TRIAL_PASS", 120 if os.getenv("RAM_TRIAL_VERSION") == "dev12.8" else 30)


def verify(logs, expected_bytes):
    lines = (logs / "report.log").read_text().splitlines()
    release = os.getenv("RAM_TRIAL_VERSION", "dev12.5")
    inventories = {
        "dev12.5": (1112, "ae129edd690fcd72820e3c286c6010474a70cefea622d53f4fe88b53f94afb21"),
        "dev12.6": (1115, "a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98"),
        "dev12.8": (1124, "a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84"),
    }
    count, digest = inventories[release]
    packages = [line for line in lines if line.startswith("RAM_TRIAL_PACKAGES ")]
    if packages != [f"RAM_TRIAL_PACKAGES count={count} digest={digest} account=locked"]:
        raise RuntimeError(f"Guest inventory or first-login account state differs from sealed {release}")
    origin = "kexec" if os.getenv("RAM_TRIAL_KEXEC") == "1" else "direct"
    if [line for line in lines if line.startswith("RAM_TRIAL_BOOT_ORIGIN=")] != [f"RAM_TRIAL_BOOT_ORIGIN={origin}"]:
        raise RuntimeError("The live DT reports a different kernel boot origin")
    if not any(re.fullmatch(r"RAM_TRIAL_SWAP zram=\d+ disk_backed=0", line) for line in lines):
        raise RuntimeError("Missing the RAM-only swap witness")
    if release != "dev12.5" and "RAM_TRIAL_SWAP zram=0 disk_backed=0" not in lines:
        raise RuntimeError(f"Expected the {release} trial to run without active swap")
    if release == "dev12.8" and "RAM_TRIAL_DESKTOP fresh=1 canary=upper-only ambient_client=ordinary auto_brightness=false" not in lines:
        raise RuntimeError("Missing the dev12.8 volatile desktop witness")
    if "RAM_TRIAL_TOPOLOGY root=overlay carrier=squashfs_ro lower=ext4_ro upper=tmpfs external_disks=0 boot_mount=0 write_confined=1" not in lines:
        raise RuntimeError("Missing the diskless RAM root topology witness")
    bounds = [match.groups() for line in lines if (match := re.fullmatch(
        r"RAM_TRIAL_PLACEMENT initrd_start=0x([a-f0-9]+) initrd_end=0x([a-f0-9]+)", line))]
    if len(bounds) != 1:
        raise RuntimeError("Missing or ambiguous live initrd placement")
    start, end = (int(value, 16) for value in bounds[0])
    if end - start != expected_bytes or not (end <= 0xbe000000 or start >= 0xbe300000):
        raise RuntimeError("Loaded initrd size or virtual framebuffer placement differs")
    mem = [int(match[1]) for line in lines if (match := re.fullmatch(r"RAM_TRIAL_MEMORY name=MemTotal kib=(\d+)", line))]
    if len(mem) != 1 or mem[0] < 8 * 1024 * 1024:
        raise RuntimeError("Virtual guest does not see the expected RAM")
    serial = (logs / "serial.log").read_bytes()
    if b"Run /y700-ram-trial-init as init process" not in serial or b"reboot: Power down" not in serial:
        raise RuntimeError("Missing the production RAM-init or normal power-off witness")
    print(f"RAM_TRIAL_PLACEMENT_CHECK initrd_bytes={expected_bytes} framebuffer_overlap=0", flush=True)


def main(work, logs, expected_bytes, command):
    virtual_ports = (
        ("qa-seed", "org.y700.ram-qa"), ("touch", "org.y700.enroll"), ("login-phase", "org.y700.login-phase"),
    )
    args = [*command, "-device", "virtio-serial-device"]
    for socket, port in virtual_ports:
        args += ["-chardev", f"socket,id={socket},path={socket}.sock,server=on,wait=off",
                 "-device", f"virtserialport,chardev={socket},name={port}"]
    args += ["-chardev", f"file,id=report,path={logs}/report.log",
             "-device", "virtserialport,chardev=report,name=org.y700.qa",
             "-serial", f"file:{logs}/serial.log", "-qmp", "unix:qmp.sock,server=on,wait=off"]
    with (logs / "qemu.log").open("xb") as qemu_log:
        guest = subprocess.Popen(args, cwd=work, stdin=subprocess.DEVNULL, stdout=qemu_log, stderr=subprocess.STDOUT)
        try:
            send_observer(work, logs, guest)
            touch_only(work, logs, guest)
            if guest.wait(190) != 0:
                raise RuntimeError("QEMU exited unsuccessfully")
            verify(logs, expected_bytes)
        except GuestBootPanic:
            if os.getenv("RAM_TRIAL_RETAIN_PANIC") == "1" and guest.poll() is None:
                try:
                    retain_initrd_prefix(work, logs, expected_bytes)
                except (OSError, RuntimeError, ValueError) as exc:
                    print(f"RAM_TRIAL_PANIC_INITRD_PREFIX unavailable={exc}", flush=True)
            raise
        finally:
            if guest.poll() is None:
                guest.terminate()
                try:
                    guest.wait(10)
                except subprocess.TimeoutExpired:
                    guest.kill()
                    guest.wait()
    print("RAM_TRIAL_QEMU_EXIT_0", flush=True)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), int(sys.argv[3]), sys.argv[4:])
