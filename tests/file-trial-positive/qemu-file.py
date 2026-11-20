"""Run the combined desktop driver with the file trial's exitrd oracle."""

from pathlib import Path
import re
import signal
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "combined-efi"))
import drive
import qemu

shared_greeter_ready = drive.greeter_ready
shared_wait_marker = drive.wait_marker


def greeter_ready(work, name):
    try:
        shared_greeter_ready(work, name)
    except TimeoutError as exc:
        if exc.args != (f"Arctica did not render the {name} keyboard prompt",):
            raise
        print(f"FILE_TRIAL_GREETER_PIXEL_RETRY prompt={name}", flush=True)
        shared_greeter_ready(work, name)


def wait_marker(work, marker, budget):
    if marker in ("COMBINED_MATCH_GREETER", "COMBINED_COLD_GREETER enrollment_skipped=1 account=configured"):
        budget += 100
    shared_wait_marker(work, marker, budget)


def exercise(work, secret, cold=False):
    drive.boot(work)
    with drive.connect(work, "login-phase.sock") as stage:
        if cold:
            wait_marker(work, "COMBINED_COLD_GREETER enrollment_skipped=1 account=configured", 260)
        else:
            wait_marker(work, "COMBINED_FIRSTBOOT_READY", 240)
            time.sleep(4)
        with drive.connect(work, "touch.sock") as sock, sock.makefile("rwb") as stream:
            if not cold:
                other = ("s" if secret[0] == "a" else "a") + secret[1:]
                drive.enter(stream, drive.ENROLL, secret, (940, 723))
                drive.enter(stream, drive.ENROLL, other, (940, 723))
                wait_marker(work, "COMBINED_MISMATCH_STILL_LOCKED", 100)
                time.sleep(3)
                drive.enter(stream, drive.ENROLL, secret, (940, 723))
                drive.enter(stream, drive.ENROLL, secret, (940, 723))
                wait_marker(work, "COMBINED_MATCH_GREETER", 220)
            greeter_ready(work, "username")
            drive.enter(stream, drive.GREETER, "y700", (894, 648))
            greeter_ready(work, "password")
            drive.enter(stream, drive.GREETER, secret, (894, 648))
            stage.sendall(b"LOGIN_SUBMITTED\n")
            wait_marker(work, "FILE_TRIAL_TOUCH_SUBMITTED acknowledged=1", 20)
            wait_marker(work, "COMBINED_PAM_XFCE account=y700 ordinary=1 active=1 local=1 seat=seat0 type=x11", 455)
            wait_marker(work, "COMBINED_PASS", 200)


def verify_file_boot(logs, cold):
    lines = (logs / "report.log").read_text().splitlines()
    account = "configured" if cold else "locked"
    boot = [line for line in lines if line.startswith("COMBINED_EFI ")]
    if len(boot) != 1 or not boot[0].endswith("account=" + account):
        raise RuntimeError("Incorrect enrollment state on file-backed boot")
    if "COMBINED_PASS" not in lines:
        raise RuntimeError("Missing file-backed desktop acceptance")
    stages = (
        r"FILE_TRIAL_TOUCH_SUBMITTED acknowledged=1",
        r"FILE_TRIAL_PAM_SESSION ordinary=1 service=lightdm seat=seat0 type=x11 elapsed=\d+s",
        r"FILE_TRIAL_XFCE_READY same_pam_session=1 elapsed=\d+s",
    )
    position = 0
    for stage in stages:
        result = [index for index, line in enumerate(lines) if re.fullmatch(stage, line)]
        if len(result) != 1 or result[0] < position:
            raise RuntimeError(f"Missing or out-of-order login stage {stage}")
        position = result[0] + 1
    boot_ids = [match[1] for line in lines if (match := re.fullmatch(r"COMBINED_BOOT_ID id=([0-9a-f-]{36})", line))]
    if len(boot_ids) != 1:
        raise RuntimeError("Expected one Linux boot ID")

    serial = (logs / "serial.log").read_bytes()
    markers = (
        rb"Booting /", rb"efi: EFI v2\.11 by Das U-Boot", rb"systemd-shutdown\[1\]: Entering exitrd\.\.\.",
        rb"EXT4-fs \(loop[0-9]+\): unmounting filesystem 171a4adb-916b-4763-9e6f-722b4a99988f",
        rb"EXT4-fs \(vda2\): unmounting filesystem ef306764-2315-4235-8796-69e2c9b61946",
        rb"y700-file-trial: clean shutdown", rb"reboot: Power down",
    )
    position = 0
    for marker in markers:
        match = re.search(marker, serial[position:])
        if match is None:
            raise RuntimeError(f"Missing ordered boot or exitrd marker {marker!r}")
        position += match.end()
    print(f"FILE_TRIAL_EXITRD_UNMOUNT inner=1 outer=1 phase={'cold' if cold else 'first'}", flush=True)
    return boot_ids[0]


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, qemu.interrupted)
    signal.signal(signal.SIGINT, qemu.interrupted)
    # Use the same authenticated input and pixels while recording the exact
    # completion of each touch submission and session phase.
    qemu.exercise = exercise
    qemu.verify_boot = verify_file_boot
    qemu.main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3], sys.argv[4:])
