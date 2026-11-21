"""Exercise the read-only kernel cache against an AArch64 U-Boot in Linux QEMU."""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ram_stage", Path(__file__).resolve().parents[2] / "scripts/uboot-ram-stage.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class Console:
    def __init__(self, process):
        self.process = process

    @property
    def in_waiting(self):
        return 65536 if select.select([self.process.stdout], [], [], 0.1)[0] else 0

    def read(self, count):
        if not self.in_waiting:
            return b""
        block = os.read(self.process.stdout.fileno(), count)
        if not block:
            raise RuntimeError("Virtual serial closed")
        return block

    def write(self, block):
        return os.write(self.process.stdin.fileno(), block)

    def interrupt_autoboot(self):
        data = bytearray()
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            data.extend(self.read(65536))
            if b"stop autoboot" in data:
                self.write(b" ")
                stage.prompt(self)
                return
        raise RuntimeError("Virtual U-Boot countdown missing")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    parser.add_argument("uboot", type=Path)
    parser.add_argument("--qemu", default="qemu-system-aarch64")
    parser.add_argument("--data")
    parser.add_argument("--initrd", type=Path, help="Also exercise a verified partial read and completing the initrd in RAM")
    args = parser.parse_args()
    kernel = args.kernel.read_bytes()
    stage.need(hashlib.sha256(kernel).hexdigest() == stage.KERNEL, "Wrong reference kernel")
    ident = uuid.uuid4()
    with tempfile.TemporaryDirectory(prefix="y700-esp-") as tmp:
        disk, fat = Path(tmp) / "disk", Path(tmp) / "fat"
        for path, size in ((disk, 70), (fat, 64)):
            with path.open("xb") as stream:
                stream.truncate(size << 20)
        table = f"label: gpt\nstart=2048,size=131072,type=uefi,uuid={ident},name=linux-boot\n"
        def run(*cmd, **kwargs):
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, **kwargs)
        run("sfdisk", disk, input=table.encode())
        run("mkfs.vfat", "-F", "32", fat)
        run("mmd", "-i", fat, "::/EFI")
        run("mcopy", "-i", fat, args.kernel, "::" + stage.ESP_KERNEL)
        if args.initrd:
            initrd = args.initrd.read_bytes()
            prefix = initrd[:stage.INITRD_PREFIX]
            stage.need(len(initrd) > len(prefix) and hashlib.sha256(prefix).hexdigest() == stage.INITRD_PREFIX_SHA,
                       "Unexpected initrd prefix")
            source = Path(tmp) / "part"
            # A daily initrd has other data after the common prefix.
            source.write_bytes(prefix + b" daily initrd")
            run("mmd", "-i", fat, "::/EFI/y700-file-12-11")
            run("mcopy", "-i", fat, source, "::" + stage.ESP_INITRD)
            source.write_bytes(initrd[len(prefix):])
            run("mcopy", "-i", fat, source, "::/suffix")
            source.write_bytes(b"dt")
            run("mcopy", "-i", fat, source, "::/short")
        run("dd", f"if={fat}", f"of={disk}", "bs=1M", "seek=1", "conv=notrunc,sparse", "status=none")
        before = digest(disk)
        cmd = [args.qemu, "-nodefaults", "-no-user-config", "-machine", "virt,gic-version=3",
               "-cpu", "cortex-a72", "-m", "512", "-serial", "stdio", "-display", "none",
               "-monitor", "none", "-nic", "none", "-bios", str(args.uboot),
               "-device", "ich9-ahci,id=ahci", "-drive", f"if=none,id=esp,format=raw,snapshot=on,file={disk}",
               "-device", "ide-hd,drive=esp,bus=ahci.0"]
        if args.data:
            cmd += ["-L", args.data]
        with subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
            try:
                port = Console(process)
                port.interrupt_autoboot()
                stage.command(port, "scsi scan")
                addr = stage.number("kernel_addr_r", stage.command(port, "printenv kernel_addr_r"))
                stage.need(0x40000000 <= addr and addr + len(kernel) <= 0x60000000, "Unexpected virtual DRAM")
                wrong = uuid.UUID(int=ident.int ^ 1)
                stage.need(stage.esp_partition(port, wrong) is None, "Wrong GPT identity accepted")
                target = stage.esp_partition(port, ident)
                stage.need(stage.esp_read(port, target, stage.ESP_KERNEL, addr, kernel), "Exact ESP kernel was not verified")
                if args.initrd:
                    ramdisk = 0x50000000
                    dt = 0x4f000000
                    stage.need(not stage.esp_read(port, target, "/short", ramdisk, prefix, allow_trailing_bytes=True),
                               "Accepted a short FAT file")
                    corrupted = bytes([prefix[0] ^ 1]) + prefix[1:]
                    stage.need(not stage.esp_read(port, target, stage.ESP_INITRD, ramdisk, corrupted, allow_trailing_bytes=True),
                               "Accepted damaged prefix")
                    writes = []
                    def complete(port, address, data):
                        path = {dt: "/short", ramdisk + len(prefix): "/suffix"}.get(address)
                        stage.need(path and stage.esp_read(port, target, path, address, data), "Wrong upload bytes or address")
                        writes.append(address)
                    with patch.object(stage, "loady", complete):
                        stage.serial_stage(port, {"kernel.efi": kernel, "initrd": initrd, "board.dtb": b"dt"},
                                           {"kernel.efi": addr, "initrd": ramdisk, "board.dtb": dt}, ident, True)
                    stage.need(writes == [dt, ramdisk + len(prefix)], "Unexpected component upload")
                    stage.verify_crc(stage.command(port, f"crc32 {ramdisk:x} {len(initrd):x}"), ramdisk, initrd)
                    stage.receipt(prefix_reassembled=1, corrupt_and_short_rejected=1)
            finally:
                process.terminate()
                process.wait(timeout=10)
        stage.need(digest(disk) == before, "Virtual backing changed")
        stage.receipt(arm64_uboot=1, esp_kernel_hit=1, usb_bytes_saved=len(kernel), wrong_guid_rejected=1,
                      backing_unchanged=1, hardware_commands=0)


if __name__ == "__main__":
    main()
