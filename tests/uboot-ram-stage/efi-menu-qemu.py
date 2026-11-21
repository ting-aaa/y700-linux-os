"""Exercise the opt-in exit from the released loader in an ARM64 U-Boot VM."""
import argparse
from pathlib import Path
import runpy
import subprocess
import tempfile

helpers = runpy.run_path(str(Path(__file__).with_name("prompt-qemu.py")))
stage = helpers["stage"]
Console = helpers["helpers"]["Console"]
LOADER = "76a5bba20322d4929f35c608199f21f80317ae006805315ca215382cdef4c75b"


def synthetic_disk(directory, loader):
    fat, disk = directory / "boot.fat", directory / "disk.img"
    for path, mib in ((fat, 64), (disk, 70)):
        with path.open("xb") as stream:
            stream.truncate(mib << 20)
    def run(*cmd, **kwargs):
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, **kwargs)
    run("mkfs.vfat", "-F", "32", fat)
    for subdir in ("/EFI", "/EFI/BOOT", "/loader", "/loader/entries"):
        run("mmd", "-i", fat, "::" + subdir)
    for target in ("/EFI/BOOT/BOOTAA64.EFI", "/EFI/test.efi"):
        run("mcopy", "-i", fat, loader, "::" + target)
    for name, content in (("loader/loader.conf", "timeout menu-force\nauto-firmware no\nauto-entries no\n"),
                          ("loader/entries/test.conf", "title Y700 QA entry\nefi /EFI/test.efi\n")):
        src = directory / Path(name).name
        src.write_text(content)
        run("mcopy", "-i", fat, src, "::/" + name)
    run("sfdisk", disk, input=b"label: gpt\nstart=2048,size=131072,type=uefi,name=linux-boot\n")
    run("dd", f"if={fat}", f"of={disk}", "bs=1M", "seek=1", "conv=notrunc,sparse", "status=none")
    return disk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("uboot", type=Path, help="QEMU U-Boot 2026.10 with CMD_BOOTMENU and CMD_PAUSE")
    parser.add_argument("loader", type=Path, help="dev12.11 EFI/BOOT/BOOTAA64.EFI")
    parser.add_argument("--qemu", default="qemu-system-aarch64")
    parser.add_argument("--data", type=Path)
    args = parser.parse_args()
    digest = helpers["helpers"]["digest"]
    stage.need(digest(args.loader) == LOADER, "Expected the released ARM64 EFI loader")
    with tempfile.TemporaryDirectory(prefix="y700-efi-menu-") as tmp:
        disk = synthetic_disk(Path(tmp), args.loader)
        original = digest(disk)
        cmd = [args.qemu, "-nodefaults", "-no-user-config", "-machine", "virt,gic-version=3",
               "-cpu", "cortex-a72", "-m", "512", "-serial", "stdio", "-display", "none",
               "-monitor", "none", "-nic", "none", "-bios", str(args.uboot),
               "-device", "ich9-ahci,id=ahci", "-drive", f"if=none,id=esp,format=raw,snapshot=on,file={disk}",
               "-device", "ide-hd,drive=esp,bus=ahci.0"]
        if args.data:
            cmd.extend(["-L", str(args.data)])
        with subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
            try:
                port = Console(proc)
                port.interrupt_autoboot()
                # The existing shell prompt was consumed. The opt-in path must
                # recover it without ever submitting its version-query key.
                stage.acquire_from_efi(port)
                stage.command(port, "scsi scan")
                for i, title in enumerate(("Boot NixOS", "Enable USB serial console", "Drop to shell", "Reset device")):
                    stage.command(port, f"setenv bootmenu_{i} '{title}=setenv y700_selection unexpected'")
                stage.command(port, "setenv y700_selection untouched")
                loaded = stage.command(port, "fatload scsi 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI")
                stage.need("bytes read" in loaded, "Virtual FAT load failed")
                port.write(b"bootefi ${kernel_addr_r}; pause; bootmenu -1\r")
                helpers["wait_for_text"](port, b"Y700 QA entry")
                stage.acquire_from_efi(port)
                value = stage.command(port, "printenv y700_selection")
                stage.need("y700_selection=untouched\n" in value, "Maintenance menu item ran unexpectedly")
            finally:
                proc.terminate()
                proc.wait(timeout=10)
        stage.need(original == digest(disk), "Virtual disk backing changed")
    print(f"UBOOT_EFI_MENU firmware_sha256={digest(args.uboot)} loader_sha256={LOADER} "
          "exit_acknowledged=1 menu_selected=0 disk_unchanged=1 hardware_commands=0")


if __name__ == "__main__":
    main()
