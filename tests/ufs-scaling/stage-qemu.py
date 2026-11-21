"""Exercise the PRC observer's read-only ext4 staging with a real QEMU U-Boot."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


here = Path(__file__).resolve().parent
observer = module("ufs_stage", here / "stage.py")
console = module("uboot_test", here.parent / "uboot-ram-stage/esp-qemu.py")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("uboot", type=Path)
    cli.add_argument("bundle", type=Path)
    cli.add_argument("variant", choices=observer.PINS)
    cli.add_argument("initrd_sha256")
    opts = cli.parse_args()
    names, blobs = observer.bundle(opts.bundle, opts.variant, opts.initrd_sha256)
    if console.digest(opts.uboot) != "ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f":
        raise ValueError("Unexpected QEMU U-Boot")
    ident = uuid.uuid4()
    addresses = {"kernel.efi": 0x44000000, "board.dtb": 0x43000000, "initrd": 0x48000000}
    with tempfile.TemporaryDirectory(prefix="y700-ufs-stage-") as tmp:
        work = Path(tmp)
        tree = work / "files/y700-ufs-observer"
        tree.mkdir(parents=True)
        for name in names.values():
            shutil.copyfile(opts.bundle / name, tree / name)
        fs, disk = work / "fs", work / "disk"
        fs_size = sum(len(blob) for blob in blobs.values()) + (40 << 20)
        sectors = (fs_size + (1 << 20) - 1) // (1 << 20) * 2048
        for path, length in ((fs, sectors * 512), (disk, (sectors + 4096) * 512)):
            with path.open("xb") as fd:
                fd.truncate(length)
        subprocess.run(["mkfs.ext4", "-q", "-F", "-b", "4096", "-O", "orphan_file,metadata_csum_seed",
                        "-d", str(tree.parent), str(fs)], check=True)
        subprocess.run(["sfdisk", str(disk)], check=True, stdout=subprocess.DEVNULL,
                       input=f"label: gpt\nstart=2048,size={sectors},uuid={ident},name=linux\n".encode())
        subprocess.run(["dd", f"if={fs}", f"of={disk}", "bs=1M", "seek=1", "conv=notrunc,sparse", "status=none"], check=True)
        before = console.digest(disk)
        args = [os.environ.get("QEMU_SYSTEM_AARCH64", "qemu-system-aarch64"), "-nodefaults", "-no-user-config",
                "-machine", "virt,gic-version=3", "-cpu", "cortex-a72", "-m", "512", "-serial", "stdio",
                "-display", "none", "-monitor", "none", "-nic", "none", "-bios", str(opts.uboot),
                "-device", "ich9-ahci,id=ahci", "-drive", f"if=none,id=linux,format=raw,file={disk}",
                "-device", "ide-hd,drive=linux,bus=ahci.0"]
        if os.environ.get("QEMU_DATA_DIR"):
            args += ["-L", os.environ["QEMU_DATA_DIR"]]
        with subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as vm:
            port = console.Console(vm)
            try:
                port.interrupt_autoboot()
                observer.stage.command(port, "pci enum")
                observer.stage.command(port, "scsi scan")
                assert observer.stage.labelled_partition(port, uuid.UUID(int=ident.int ^ 1), "linux") is None
                target = observer.stage.labelled_partition(port, ident, "linux")
                assert target is not None
                assert not observer.stage.verified_file_read(port, target, "/y700-ufs-observer/initrd", addresses["initrd"],
                                                            bytes([blobs["initrd"][0] ^ 1]) + blobs["initrd"][1:], "ext4")
                observer.load_from_linux(port, ident, names, blobs, addresses)
            finally:
                vm.kill()
                vm.wait()
        assert console.digest(disk) == before
    print(f"OBSERVER_UBOOT variant={opts.variant} wrong_uuid_rejected=1 wrong_crc_rejected=1 original_disk_hash_equal=1 boot_requests=0")


if __name__ == "__main__":
    main()
