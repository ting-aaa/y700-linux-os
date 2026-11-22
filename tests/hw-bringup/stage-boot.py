# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial==3.5"]
# ///
"""Stage and boot the volatile RAM-overlay hardware verification bundle via PRC U-Boot."""
import argparse
from contextlib import closing
import hashlib
import importlib.util
from pathlib import Path
import sys
import uuid


spec = importlib.util.spec_from_file_location(
    "ram_stage", Path(__file__).resolve().parents[2] / "scripts/uboot-ram-stage.py"
)
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

CMDLINE = (
    "rdinit=/y700-hw-overlay-init y700.hw_trial=1 fstab=no systemd.gpt_auto=0 noresume "
    "panic=15 console=ttyMSM0,115200n8 console=tty0 "
    "androidboot.hardware=qcom androidboot.console=ttyMSM0 "
    "androidboot.usbcontroller=a600000.usb androidboot.boot_devices=soc/1d84000.ufshc "
    "clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle "
    "drm_kms_helper.fbdev_emulation=0"
)


def load_bundle(directory: Path):
    sums = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        digest, name = line.split(None, 1)
        sums[name.strip()] = digest.strip()
    blobs = {}
    for slot in ("kernel.efi", "board.dtb", "initrd"):
        path = directory / slot
        blob = path.read_bytes()
        stage.need(0 < len(blob) <= stage.SLOTS[slot][1], f"{slot} exceeds RAM slot")
        stage.need(hashlib.sha256(blob).hexdigest() == sums[slot], f"{slot} SHA-256 mismatch")
        blobs[slot] = blob
    return blobs


def load_from_linux(port, part_uuid, remote_dir, blobs, addresses):
    target = stage.labelled_partition(port, part_uuid, "linux")
    stage.need(target is not None, "Linux backing partition not found")
    for slot in ("kernel.efi", "board.dtb", "initrd"):
        matched = stage.verified_file_read(
            port, target, f"{remote_dir}/{slot}", addresses[slot], blobs[slot], "ext4"
        )
        stage.need(matched, f"U-Boot ext4load/CRC mismatch for {slot}")
    stage.verify_staged_board(port, blobs, addresses)
    stage.receipt(target_crcs=3, ufs_ro_overlay_trial=1)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("action", choices=("check", "boot"))
    cli.add_argument("directory", type=Path)
    cli.add_argument("--linux-partuuid", type=uuid.UUID)
    cli.add_argument("--remote-dir", default="/y700-hw-bringup")
    cli.add_argument("--wait-seconds", type=int, default=120)
    args = cli.parse_args()
    if args.action == "boot" and args.linux_partuuid is None:
        cli.error("boot requires --linux-partuuid")
    blobs = load_bundle(args.directory)
    stage.receipt(host_verified=3, total_bytes=sum(len(b) for b in blobs.values()))
    if args.action == "check":
        return
    stage.receipt(acm_wait_s=args.wait_seconds)
    with closing(stage.connect(args.wait_seconds, exit_efi_menu=True)) as port:
        addresses = stage.inspect(port)
        try:
            load_from_linux(port, args.linux_partuuid, args.remote_dir, blobs, addresses)
        except stage.Refused:
            stage.inspect(port)
            stage.write(port, b"reset\r")
            stage.receipt(default_reset_requested=1)
            raise
        stage.boot_verified(port, blobs, addresses, CMDLINE)


if __name__ == "__main__":
    try:
        main()
    except (stage.Refused, OSError, ValueError) as error:
        sys.exit(
            str(error)
            if isinstance(error, stage.Refused)
            else f"HW trial stage/boot failed ({type(error).__name__}: {error})"
        )
