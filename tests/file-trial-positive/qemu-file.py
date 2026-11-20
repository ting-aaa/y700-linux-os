"""Run the combined desktop driver with the file trial's exitrd oracle."""

from functools import partial
import os
from pathlib import Path
import re
import signal
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "combined-efi"))
import drive
import qemu

shared_greeter_ready = drive.greeter_ready


def greeter_ready(work, name):
    try:
        shared_greeter_ready(work, name)
    except TimeoutError as exc:
        if exc.args != (f"Arctica did not render the {name} keyboard prompt",):
            raise
        print(f"FILE_TRIAL_GREETER_PIXEL_RETRY prompt={name}", flush=True)
        shared_greeter_ready(work, name)


def guest_stopped(pid):
    # The QEMU child remains ours until the shared launcher reaps it, so the
    # PID cannot refer to a replacement process during this wait.
    try:
        return any(line.startswith("State:\tZ") for line in Path(f"/proc/{pid}/status").read_text().splitlines())
    except FileNotFoundError:
        return True


def wait_marker(work, guest_pid, marker, budget):
    if marker in ("COMBINED_MATCH_GREETER", "COMBINED_COLD_GREETER enrollment_skipped=1 account=configured"):
        budget += 100
    deadline = time.monotonic() + budget
    report = work / "report.log"
    while time.monotonic() < deadline:
        lines = report.read_text(errors="replace").splitlines()
        if any(line.startswith("COMBINED_FAIL ") for line in lines):
            raise RuntimeError("Guest observer reported a failure")
        if marker in lines:
            print(marker, flush=True)
            return
        if guest_stopped(guest_pid):
            known = ("COMBINED_", "FILE_TRIAL_")
            last = next((line.split()[0] for line in reversed(lines) if line.startswith(known)), "none")
            serial = report.resolve().with_name("serial.log").read_bytes()
            print(f"FILE_TRIAL_GUEST_ENDED pending={marker.split()[0]} last_stage={last} "
                  f"powerdown={int(b'reboot: Power down' in serial)}", flush=True)
            raise RuntimeError("QEMU exited before the required guest stage")
        time.sleep(0.8)
    raise TimeoutError(marker)


def relay_desktop_taps(work, stage, touch_socket, stream, guest_pid=None):
    deadline = time.monotonic() + 1000
    next_seq = 1
    with (work / "report.log").open() as report:
        while time.monotonic() < deadline:
            position = report.tell()
            line = report.readline()
            if not line.endswith("\n"):
                report.seek(position)
                if guest_pid is not None and guest_stopped(guest_pid):
                    print("FILE_TRIAL_DESKTOP_RELAY status=guest-ended", flush=True)
                    return
                time.sleep(0.25)
                continue
            line = line.rstrip("\n")
            if line == "DESKTOP_ACTIONS_DONE" or re.fullmatch(
                r"FILE_TRIAL_DESKTOP_ACTIONS status=(?:passed|failed) exit=[0-9]+", line
            ):
                print(f"FILE_TRIAL_DESKTOP_RELAY status=complete taps={next_seq - 1}", flush=True)
                return
            if not line.startswith("DESKTOP_TAP "):
                continue
            request = re.fullmatch(r"DESKTOP_TAP ([0-9]{1,3}) ([0-9]{1,4}) ([0-9]{1,4})", line)
            if request is not None:
                seq, x, y = map(int, request.groups())
            if request is None or seq != next_seq or seq > 512 or not (0 <= x < 1024 and 0 <= y < 768):
                print("FILE_TRIAL_DESKTOP_RELAY status=invalid-request", flush=True)
                return
            try:
                touch_socket.settimeout(min(20, max(0.1, deadline - time.monotonic())))
                stream.write(f"tap {x} {y}\n".encode("ascii"))
                stream.flush()
                if stream.readline().strip() != b"OK":
                    print("FILE_TRIAL_DESKTOP_RELAY status=touch-unacknowledged", flush=True)
                    return
                stage.sendall(f"TAP_OK {seq}\n".encode("ascii"))
            except OSError:
                print("FILE_TRIAL_DESKTOP_RELAY status=socket-error", flush=True)
                return
            next_seq += 1
    print("FILE_TRIAL_DESKTOP_RELAY status=deadline-exceeded", flush=True)


def exercise(work, secret, cold=False, *, desktop_actions=False):
    children = Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()
    if len(children) != 1:
        raise RuntimeError("The EFI fixture expected a single QEMU child")
    guest_pid = int(children[0])
    wait = partial(wait_marker, work, guest_pid)
    drive.boot(work)
    with drive.connect(work, "login-phase.sock") as stage:
        if cold:
            wait("COMBINED_COLD_GREETER enrollment_skipped=1 account=configured", 260)
        else:
            wait("COMBINED_FIRSTBOOT_READY", 240)
            time.sleep(4)
        with drive.connect(work, "touch.sock") as sock, sock.makefile("rwb") as stream:
            if not cold:
                other = ("s" if secret[0] == "a" else "a") + secret[1:]
                drive.enter(stream, drive.ENROLL, secret, (940, 723))
                drive.enter(stream, drive.ENROLL, other, (940, 723))
                wait("COMBINED_MISMATCH_STILL_LOCKED", 100)
                time.sleep(3)
                drive.enter(stream, drive.ENROLL, secret, (940, 723))
                drive.enter(stream, drive.ENROLL, secret, (940, 723))
                wait("COMBINED_MATCH_GREETER", 220)
            greeter_ready(work, "username")
            drive.enter(stream, drive.GREETER, "y700", (894, 648))
            greeter_ready(work, "password")
            drive.enter(stream, drive.GREETER, secret, (894, 648))
            stage.sendall(b"LOGIN_SUBMITTED\n")
            wait("FILE_TRIAL_TOUCH_SUBMITTED acknowledged=1", 20)
            wait("COMBINED_PAM_XFCE account=y700 ordinary=1 active=1 local=1 seat=seat0 type=x11", 455)
            if desktop_actions:
                relay_desktop_taps(work, stage, sock, stream, guest_pid)
            wait("COMBINED_PASS", 200)


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
    work, out, disk, mode, *command = sys.argv[1:]
    work, out = Path(work).resolve(), Path(out).resolve()
    qemu.exercise = partial(exercise, desktop_actions=mode == "desktop-actions")
    qemu.verify_boot = verify_file_boot
    if mode == "desktop-actions":
        qemu.launch(work / "first", out / "first", command,
                    f"file={disk},format=qcow2,if=none,id=disk", drive.make_secret())
    elif mode == "double":
        qemu.main(work, out, disk, command)
    else:
        raise SystemExit("Unknown file trial phase mode")
