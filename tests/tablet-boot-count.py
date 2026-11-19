"""Run the installed EFI loader against a private writable FAT disk across three resets."""

import argparse
import os
import select
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
for arg in ("board", "qemu", "work"):
    p.add_argument(arg, type=Path)
args = p.parse_args()
board, qemu, work = (x.resolve() for x in (args.board, args.qemu, args.work))
work.mkdir(mode=0o700)
disk = work / "disk.gpt"


def run(*cmd, **options):
    return subprocess.run(cmd, check=True, **options)


with disk.open("xb") as stream:
    stream.truncate(145 * 1024**2)
run(
    "sfdisk",
    "--sector-size",
    "4096",
    disk,
    input=b"label: gpt\nstart=256,size=36352,type=uefi,name=linux-boot\n",
)
fat = work / "esp.fat"
with fat.open("xb") as stream:
    stream.truncate(142 * 1024**2)
run("mkfs.fat", "-F", "16", "-S", "4096", fat)
for d in ("EFI", "EFI/BOOT", "EFI/debian", "loader", "loader/entries"):
    run("mmd", "-i", fat, "::/" + d)
for src, dst in [
    (board / "efi/esp/EFI/BOOT/BOOTAA64.EFI", "EFI/BOOT/BOOTAA64.EFI"),
    (board / "linux-7.3.4/arch/arm64/boot/Image", "EFI/debian/kernel.efi"),
    (board / "efi/vm/board.dtb", "EFI/debian/board.dtb"),
]:
    run("mcopy", "-i", fat, src, "::/" + dst)


def put(name, content):
    src = work / Path(name).name
    src.write_text(content)
    run("mcopy", "-i", fat, src, "::/" + name)


put("loader/loader.conf", "default y700-lab-*.conf\ntimeout 0\n")
for role, filename, order in [("trial", "trial+2", "00"), ("return", "base", "99")]:
    put(
        "loader/entries/y700-lab-" + filename + ".conf",
        f"title {role}\nsort-key {order}-y700\nlinux /EFI/debian/kernel.efi\n"
        f"devicetree /EFI/debian/board.dtb\noptions console=ttyAMA0 root=/dev/vda2 panic=3 y700.lab_vm={role}\n",
    )
run(
    "dd",
    "if=" + str(fat),
    "of=" + str(disk),
    "bs=1M",
    "seek=1",
    "conv=notrunc,sparse",
    "status=none",
)
libs = qemu / "usr/lib/x86_64-linux-gnu"
env = dict(os.environ, LD_LIBRARY_PATH=str(libs), QEMU_MODULE_DIR=str(libs / "qemu"))
for boot, role in enumerate(("trial", "trial", "return"), 1):
    command = [
        qemu / "usr/bin/qemu-system-aarch64",
        "-L",
        qemu / "usr/share/qemu",
        "-machine",
        "virt,gic-version=3",
        "-cpu",
        "max",
        "-m",
        "2048",
        "-smp",
        "2",
        "-nodefaults",
        "-display",
        "none",
        "-nic",
        "none",
        "-monitor",
        "none",
        "-serial",
        "stdio",
        "-bios",
        board / "efi/qemu-uboot/u-boot.bin",
        "-no-reboot",
        "-drive",
        f"file={disk},format=raw,if=none,id=d,cache=writethrough",
        "-device",
        "virtio-blk-device,drive=d,logical_block_size=4096,physical_block_size=4096",
    ]
    proc = subprocess.Popen(
        command,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        text = b""
        phase = 0
        limit = time.monotonic() + 100
        with (work / f"boot-{boot}.log").open("xb", buffering=0) as log:
            while time.monotonic() < limit:
                if not select.select([proc.stdout], [], [], 1)[0]:
                    continue
                data = os.read(proc.stdout.fileno(), 65536)
                if not data:
                    if (
                        phase == 3
                        and b"Kernel panic" in text
                        and b"Rebooting in 3 seconds" in text
                    ):
                        if proc.wait(timeout=8) != 0:
                            raise RuntimeError(
                                "QEMU failed before the expected panic reset"
                            )
                        break
                    raise RuntimeError(
                        "guest exited before reaching the expected kernel"
                    )
                log.write(data)
                text = (text + data)[-65536:]
                if phase == 0 and b"autoboot" in text.lower():
                    proc.stdin.write(b"\r")
                    proc.stdin.flush()
                    phase = 1
                if phase == 1 and b"=> " in text:
                    proc.stdin.write(
                        b"virtio scan; fatload virtio 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; bootefi ${kernel_addr_r}\r"
                    )
                    proc.stdin.flush()
                    phase = 2
                if phase == 2 and any(
                    b"Kernel command line:" in l and f"y700.lab_vm={role}".encode() in l
                    for l in text.splitlines()
                ):
                    if boot == 1:
                        # There is no root partition. Let the kernel panic and actually reset.
                        phase = 3
                    else:
                        break
            else:
                raise TimeoutError(f"boot {boot}, see {log.name}")
    finally:
        proc.terminate()
        proc.wait(timeout=15)
    entries = subprocess.check_output(
        ["mdir", "-b", "-i", str(disk) + "@@1048576", "::/loader/entries/"]
    )
    counted = ("trial+1-1.conf" if boot == 1 else "trial+0-2.conf").encode()
    assert counted in entries, entries
    print(f"boot {boot}: {role}, counter {counted.decode()}", flush=True)
