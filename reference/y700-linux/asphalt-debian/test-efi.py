"""Run QEMU from reset through U-Boot, systemd-boot and the Debian desktop."""
import os
from pathlib import Path
import select
import subprocess
import sys
import time

w, bundle = map(lambda arg: Path(arg).resolve(), sys.argv[1:3])
env = dict(os.environ, LD_LIBRARY_PATH=str(bundle / "usr/lib/x86_64-linux-gnu"),
           QEMU_MODULE_DIR=str(bundle / "usr/lib/x86_64-linux-gnu/qemu"))
args = [bundle / "usr/bin/qemu-system-aarch64", "-machine", "virt,gic-version=3",
        "-cpu", "max", "-smp", "3", "-m", "2048", "-nodefaults", "-no-user-config",
        "-display", "none", "-nic", "none", "-monitor", f"unix:{w}/vm/monitor.sock,server=on,wait=off", "-serial", "stdio",
        "-L", bundle / "usr/share/qemu", "-bios", w / "qemu-uboot/u-boot.bin",
        "-drive", f"file={w}/vm/disk.gpt,format=raw,if=none,id=disk,snapshot=on",
        "-device", "virtio-blk-device,drive=disk,logical_block_size=4096,physical_block_size=4096"]
proc = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
phase = "reset"
recent = b""
def send(line):
    proc.stdin.write(line)
    proc.stdin.flush()

checks = b"""
echo "EFI-guest: root=$(findmnt -nro SOURCE /) esp=$(findmnt -nro SOURCE /boot) kernel=$(uname -r) PID1=$(cat /proc/1/comm)"
echo "EFI loader info:"; for f in /sys/firmware/efi/efivars/LoaderInfo-*; do test -f "$f" && tail -c +5 "$f" | iconv -f UTF-16LE -t UTF-8; done; echo
mkdir -p /etc/lightdm/lightdm.conf.d
printf '[Seat:*]\\nautologin-user=y700\\nautologin-session=xfce\\n' > /etc/lightdm/lightdm.conf.d/90-vm-test.conf
touch /etc/y700/user-configured
systemctl restart lightdm
for i in $(seq 1 60); do pgrep -x xfce4-session >/dev/null && pgrep -x xfwm4 >/dev/null && break; sleep 1; done
test -d /sys/firmware/efi && test "$(uname -r)" = 7.3.4-asphalt-prc && test "$(findmnt -nro SOURCE /)" = /dev/vda2 && test "$(findmnt -nro SOURCE /boot)" = /dev/vda1 && test "$(findmnt -nro FSTYPE /boot)" = vfat && test -f /boot/EFI/BOOT/BOOTAA64.EFI && test "$(cat /proc/1/comm)" = systemd && pgrep -x xfce4-session && pgrep -x xfwm4 && printf 'EFI_%s\\n' DEBIAN_DESKTOP_OK
"""
with (w / "vm/efi-serial.log").open("wb", buffering=0) as log:
    try:
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline and proc.poll() is None:
            if not select.select([proc.stdout], [], [], 2)[0]:
                continue
            data = os.read(proc.stdout.fileno(), 65536)
            if not data:
                break
            log.write(data)
            recent = (recent + data)[-8192:]
            if phase == "reset" and b"autoboot" in recent.lower():
                send(b"\r")
                phase = "uboot"
            if phase == "uboot" and b"=> " in recent:
                send(b"virtio scan; part number virtio 0 linux-boot bootpart; "
                     b"if fatload virtio 0:${bootpart} ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; "
                     b"then bootefi ${kernel_addr_r}; fi\r")
                phase, recent = "linux", b""
            if phase == "linux" and b"root@y700-linux:" in recent:
                send(checks)
                phase, recent = "desktop", b""
            if phase == "desktop" and b"EFI_DEBIAN_DESKTOP_OK" in recent:
                break
        if b"EFI_DEBIAN_DESKTOP_OK" not in recent:
            raise RuntimeError(f"EFI VM stopped at {phase}. See vm/efi-serial.log")
        print("Verified EFI boot of Debian, ESP mount and Xfce session.")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=6)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
