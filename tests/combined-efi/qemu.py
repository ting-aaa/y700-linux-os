"""Run one or two independent EFI boots with a disposable writable disk."""

import os
from pathlib import Path
import re
import signal
import subprocess
import sys

from drive import exercise, make_secret


def verify_boot(logs, cold):
    report = (logs / "report.log").read_text().splitlines()
    for required in (
        "COMBINED_TOUCH ", "COMBINED_ONBOARD ", "COMBINED_AUDIO_PANEL ", "COMBINED_PASS",
    ):
        if not any(line.startswith(required) for line in report):
            raise RuntimeError(f"Missing guest marker: {required}")
    account = "configured" if cold else "locked"
    if not any(line.startswith("COMBINED_EFI ") and line.endswith("account=" + account) for line in report):
        raise RuntimeError("Unexpected account state during EFI boot")
    serial = (logs / "serial.log").read_bytes()
    if any(marker not in serial for marker in (
        b"Booting /", b"efi: EFI v2.11 by Das U-Boot",
        b"systemd-shutdown[1]: Powering off.", b"reboot: Power down",
    )):
        raise RuntimeError("Missing U-Boot, EFI or power-off evidence")
    ids = [match[1] for line in report if (match := re.fullmatch(r"COMBINED_BOOT_ID id=([0-9a-f-]{36})", line))]
    if len(ids) != 1:
        raise RuntimeError("Missing or ambiguous guest boot ID")
    return ids[0]


def launch(work, logs, command, drive, secret, cold=False):
    work.mkdir(mode=0o700)
    logs.mkdir(mode=0o700)
    (work / "report.log").symlink_to(logs / "report.log")
    args = [*command,
            "-chardev", "socket,id=taps,path=touch.sock,server=on,wait=off",
            "-device", "virtserialport,chardev=taps,name=org.y700.enroll",
            "-chardev", f"file,id=report,path={logs}/report.log",
            "-device", "virtserialport,chardev=report,name=org.y700.qa",
            "-chardev", f"socket,id=serial,path=serial.sock,server=on,wait=off,logfile={logs}/serial.log",
            "-serial", "chardev:serial", "-qmp", "unix:qmp.sock,server=on,wait=off",
            "-drive", drive, "-device", "virtio-blk-device,drive=disk,logical_block_size=4096,physical_block_size=4096"]
    env = dict(os.environ, TMPDIR=str(work))
    if env.get("QEMU_LIB"):
        env["LD_LIBRARY_PATH"] = env["QEMU_LIB"]
    with (logs / "qemu.log").open("xb") as log:
        guest = subprocess.Popen(args, cwd=work, env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT)
        try:
            exercise(work, secret, cold)
            if guest.wait(timeout=190) != 0:
                raise RuntimeError("QEMU exited unsuccessfully")
        finally:
            if guest.poll() is None:
                guest.terminate()
                try:
                    guest.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    guest.kill()
                    guest.wait()
    boot_id = verify_boot(logs, cold)
    phase = "cold" if cold else "first"
    print(f"COMBINED_QEMU_EXIT_0 phase={phase}", flush=True)
    return boot_id


def main(work, output, cold_disk, command):
    secret = make_secret()
    if cold_disk == "-":
        launch(work / "first", output / "first", command,
               f"file={work}/view/disk.gpt,format=raw,if=none,id=disk,snapshot=on", secret)
        return
    # QEMU commits all writes to this scratch child only. Use the same child
    # after completely stopping the first process. Keep its password in RAM.
    drive = f"file={cold_disk},format=qcow2,if=none,id=disk"
    first = launch(work / "first", output / "first", command, drive, secret)
    second = launch(work / "cold", output / "cold", command, drive, secret, cold=True)
    if first == second:
        raise RuntimeError("The two guests reported the same kernel boot ID")
    print("COMBINED_COLD_RELOGIN_PASS two_processes=1 boot_ids_distinct=1 overlay_reused=1", flush=True)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3], sys.argv[4:])
