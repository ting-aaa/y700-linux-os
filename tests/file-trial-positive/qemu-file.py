"""Run the combined desktop driver with the file trial's exitrd oracle."""

from pathlib import Path
import re
import signal
import sys

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


def verify_file_boot(logs, cold):
    lines = (logs / "report.log").read_text().splitlines()
    account = "configured" if cold else "locked"
    boot = [line for line in lines if line.startswith("COMBINED_EFI ")]
    if len(boot) != 1 or not boot[0].endswith("account=" + account):
        raise RuntimeError("Incorrect enrollment state on file-backed boot")
    if "COMBINED_PASS" not in lines:
        raise RuntimeError("Missing file-backed desktop acceptance")
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
    # Keep its exact touch and pixel checks with a longer virtual greeter budget.
    drive.greeter_ready = greeter_ready
    drive.wait_marker = wait_marker
    qemu.verify_boot = verify_file_boot
    qemu.main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3], sys.argv[4:])
