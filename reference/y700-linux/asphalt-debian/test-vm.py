"""Boot the extracted Android payload with the exFAT or UFS-profile root.

The virtual board supplies a simple framebuffer and a serial debug shell. The
temporary QEMU overlay is the only place where the test enables autologin.
"""
import os
import select
import subprocess
import sys
import time
from pathlib import Path

work, qemu = map(lambda arg: Path(arg).resolve(), sys.argv[1:3])
ufs = sys.argv[3:] == ["ufs"]
if sys.argv[3:] and not ufs:
    raise SystemExit("Optional third argument must be ufs")
disk = work / ("vm-ufs.gpt" if ufs else "vm-media.exfat")
device = "virtio-blk-device,drive=rootdisk"
if ufs:
    device += ",logical_block_size=4096,physical_block_size=4096"
env = dict(os.environ, LD_LIBRARY_PATH=str(qemu / "usr/lib/x86_64-linux-gnu"),
           QEMU_MODULE_DIR=str(qemu / "usr/lib/x86_64-linux-gnu/qemu"))
board = [str(qemu / "usr/bin/qemu-system-aarch64"), "-machine", "virt,gic-version=3",
         "-cpu", "max", "-smp", "3", "-m", "2048", "-nodefaults", "-no-user-config",
         "-display", "none", "-nic", "none", "-L", str(qemu / "usr/share/qemu")]
dt = work / "vm-fb.dtb"
dump = board.copy()
dump[2] += ",dumpdtb=" + str(dt)
subprocess.run(dump, env=env, check=True)
def put(node, prop=None, *values, kind="x"):
    args = ["fdtput", "-p", "-t", kind, dt, node, prop, *values] if prop else ["fdtput", "-cp", dt, node]
    subprocess.run(args, check=True)
reserve = "/reserved-memory"
fb = "/chosen/framebuffer@be000000"
put(reserve, "#address-cells", "2")
put(reserve, "#size-cells", "2")
put(reserve, "ranges")
put(reserve + "/framebuffer@be000000", "reg", "0", "be000000", "0", "300000")
put(reserve + "/framebuffer@be000000", "no-map")
put("/chosen", "#address-cells", "2")
put("/chosen", "#size-cells", "2")
put("/chosen", "ranges")
put(fb, "compatible", "simple-framebuffer", kind="s")
put(fb, "reg", "0", "be000000", "0", "300000")
put(fb, "width", "400")
put(fb, "height", "300")
put(fb, "stride", "1000")
put(fb, "format", "a8r8g8b8", kind="s")
args = board + ["-dtb", str(dt), "-serial", "stdio", "-monitor", "none",
                "-drive", f"file={disk},format=raw,if=none,id=rootdisk,snapshot=on",
                "-device", device, "-kernel", str(work / "unpacked/kernel"),
                "-initrd", str(work / "unpacked/ramdisk"), "-append",
                "console=ttyAMA0 rdinit=/init loglevel=4 systemd.debug_shell=ttyAMA0 "
                "systemd.mask=serial-getty@ttyAMA0.service systemd.mask=y700-firstboot.service"]
proc = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
serial = proc.stdout.fileno()
buffer = b""
sent = False
with (work / "vm.log").open("wb", buffering=0) as log:
    try:
        stop = time.monotonic() + 210
        while time.monotonic() < stop and proc.poll() is None:
            if not select.select([serial], [], [], 2)[0]:
                continue
            data = os.read(serial, 65536)
            if not data:
                break
            log.write(data)
            buffer = (buffer + data)[-16384:]
            if not sent and (b"# " in buffer or b"Cannot access job control" in buffer):
                # Built in two pieces so terminal echo cannot match the result.
                script = """
echo "VM root=$(findmnt -nro SOURCE /) media=$(findmnt -nro FSTYPE /run/y700-media) kernel=$(uname -r) pid1=$(cat /proc/1/comm)"
mkdir -p /etc/lightdm/lightdm.conf.d
printf '[Seat:*]\\nautologin-user=y700\\nautologin-session=xfce\\n' >/etc/lightdm/lightdm.conf.d/90-vm-test.conf
touch /etc/y700/user-configured
systemctl restart lightdm
for i in $(seq 1 60); do pgrep -x xfce4-session >/dev/null && pgrep -x xfwm4 >/dev/null && break; sleep 1; done
test "$(uname -r)" = 7.3.4-asphalt-prc && test "$(findmnt -nro FSTYPE /run/y700-media)" = exfat && test "$(cat /proc/1/comm)" = systemd && systemctl is-active lightdm && pgrep -x xfce4-session && pgrep -x xfwm4 && printf 'ASPHALT_%s\\n' VM_DESKTOP_OK
"""
                if ufs:
                    script = script.replace('test "$(findmnt -nro FSTYPE /run/y700-media)" = exfat',
                        'test "$(findmnt -nro SOURCE /)" = /dev/vda1 && '
                        'grep -qx PARTNAME=linux /sys/class/block/vda1/uevent && '
                        'test "$(cat /sys/class/block/vda/queue/logical_block_size)" = 4096 && '
                        'test ! -e /run/y700-media && test -z "$(ls -d /sys/class/block/mmcblk* 2>/dev/null)"')
                proc.stdin.write(script.encode())
                proc.stdin.flush()
                sent = True
            if b"ASPHALT_VM_DESKTOP_OK" in buffer:
                print(f"QEMU booted the {'4K GPT partition' if ufs else 'exFAT-hosted root'}, systemd, LightDM, Xfce and xfwm4.")
                break
        else:
            raise RuntimeError(f"VM stopped or timed out; inspect {work}/vm.log")
        if b"ASPHALT_VM_DESKTOP_OK" not in buffer:
            raise RuntimeError(f"Incomplete serial proof; inspect {work}/vm.log")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
