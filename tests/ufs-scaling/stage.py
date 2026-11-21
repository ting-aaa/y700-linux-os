# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial==3.5"]
# ///
"""Load the isolated UFS observer from the Linux data partition using the PRC U-Boot."""
import argparse
from contextlib import closing
import hashlib
import importlib.util
from pathlib import Path
import re
import sys
import uuid


spec = importlib.util.spec_from_file_location("ram_stage", Path(__file__).resolve().parents[2] / "scripts/uboot-ram-stage.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

PINS = {
    "stock": (stage.KERNEL, "7578715cea3c1acbbc8bcc7f60226e8e4bbe6c6b296cba5696f9f5128b9a0d3a"),
    "candidate": ("243db9c43ef8f7a4a3e224106d87f2c87ba16c1ce93c475c4eafa02f8817fce6",
                  "df17a0afb947a7adff4631d0ad9ee888629ac2c6523a5db28865c368915025c2"),
}
CMDLINE = ("rdinit=/init y700.ufs_observe=1 noresume panic=5 console=ttyMSM0,115200n8 console=tty0 "
           "androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.usbcontroller=a600000.usb "
           "clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle drm_kms_helper.fbdev_emulation=0")


def bundle(directory, variant, initrd_sha256):
    stage.need(re.fullmatch(r"[0-9a-f]{64}", initrd_sha256), "Invalid observer initrd identifier")
    names = {"kernel.efi": variant + "-image", "board.dtb": variant + ".dtb", "initrd": "initrd"}
    kernel, dt = PINS[variant]
    hashes = {"kernel.efi": kernel, "board.dtb": dt, "initrd": initrd_sha256}
    blobs = {}
    for slot, name in names.items():
        file = directory / name
        stage.need(0 < file.stat().st_size <= stage.SLOTS[slot][1], "Observer payload exceeds RAM slot")
        blob = file.read_bytes()
        stage.need(hashlib.sha256(blob).hexdigest() == hashes[slot], "Unexpected observer payload")
        blobs[slot] = blob
    return names, blobs


def load_from_linux(port, part_uuid, names, blobs, addresses):
    target = stage.labelled_partition(port, part_uuid, "linux")
    stage.need(target is not None, "Original Linux data partition did not match")
    for slot, name in names.items():
        matched = stage.verified_file_read(port, target, "/y700-ufs-observer/" + name,
                                           addresses[slot], blobs[slot], "ext4")
        stage.need(matched, "Read-only observer file load did not match")
    stage.verify_staged_board(port, blobs, addresses)
    for node, expected in zip(stage.CONTROLLERS, ("okay", "disabled"), strict=True):
        status = stage.one(r'^status = "(\w+)"$', stage.command(port, f"fdt print {node} status"))
        stage.need(status == expected, "Unexpected UFS or microSD state")
    stage.receipt(target_crcs=3, ufs_enabled=1, sd_disabled=1)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("action", choices=("check", "boot"))
    cli.add_argument("directory", type=Path)
    cli.add_argument("variant", choices=PINS)
    cli.add_argument("initrd_sha256")
    cli.add_argument("--linux-partuuid", type=uuid.UUID)
    args = cli.parse_args()
    if args.action == "boot" and args.linux_partuuid is None:
        cli.error("boot requires the reference Linux partition UUID")
    names, blobs = bundle(args.directory, args.variant, args.initrd_sha256)
    stage.receipt(host_verified=3)
    if args.action == "check":
        return
    stage.receipt(acm_wait_s=120)
    with closing(stage.connect(120, exit_efi_menu=True)) as port:
        addresses = stage.inspect(port)
        try:
            load_from_linux(port, args.linux_partuuid, names, blobs, addresses)
        except stage.Refused:
            # A pre-boot rejection can leave a working firmware shell at its prompt.
            # Recheck the PRC and RAM map before requesting its normal default boot.
            stage.inspect(port)
            stage.write(port, b"reset\r")
            stage.receipt(default_reset_requested=1)
            raise
        stage.boot_verified(port, blobs, addresses, CMDLINE)


if __name__ == "__main__":
    try:
        main()
    except (stage.Refused, OSError, ValueError) as error:
        sys.exit(str(error) if isinstance(error, stage.Refused) else f"Observer input/transport failed ({type(error).__name__})")
