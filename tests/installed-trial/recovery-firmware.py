"""Boot the actual boot manager and wait for its selected EFI variable on serial."""
import os
from pathlib import Path
import select
import subprocess
import sys
import time

bios, role, mode = sys.argv[1:]
assert mode in ("recovery", "rtc1", "cci0")
assert role in ("trial", "base")
command = [os.getenv("QEMU_SYSTEM_AARCH64", "qemu-system-aarch64")]
if env_dir := os.getenv("QEMU_DATA"):
    command += ["-L", env_dir]
command += ["-M", "virt,gic-version=3", "-cpu", "max", "-smp", "2", "-m", "2048",
            "-nodefaults", "-no-user-config", "-no-reboot", "-display", "none", "-nic", "none",
            "-monitor", "none", "-serial", "stdio", "-bios", bios,
            "-drive", "file=menu.gpt,format=raw,if=none,id=d,cache=writethrough",
            "-device", "virtio-blk-device,drive=d,logical_block_size=4096,physical_block_size=4096"]
marker = f"RECOVERY_EFI selected=y700-installed-recovery-qarecovery-{role}.conf recovery={int(role == 'trial')}"
if mode == "rtc1":
    marker = f"RTC1_EFI selected=y700-installed-rtc1-qartc-{role}.conf virtual_alias={int(role == 'trial')}"
if mode == "cci0":
    marker = f"CCI0_EFI selected=y700-installed-cci0-qacci-{role}.conf virtual_assignment={int(role == 'trial')}"
with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as vm:
    try:
        buffer = b""
        phase = 0
        deadline = time.monotonic() + 100
        with Path(f"{role}.log").open("xb") as log:
            while time.monotonic() < deadline:
                if not select.select([vm.stdout], [], [], 1)[0]:
                    continue
                part = os.read(vm.stdout.fileno(), 65536)
                if not part:
                    break
                log.write(part)
                buffer = (buffer + part)[-65536:]
                if phase == 0 and b"autoboot" in buffer.lower():
                    vm.stdin.write(b"\r")
                    vm.stdin.flush()
                    phase = 1
                if phase == 1 and b"=> " in buffer:
                    vm.stdin.write(b"virtio scan; fatload virtio 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; bootefi ${kernel_addr_r}\r")
                    vm.stdin.flush()
                    phase = 2
        assert marker.encode() in buffer and vm.wait(timeout=3) == 0, f"{role} failed, inspect {role}.log"
        print(marker, flush=True)
    finally:
        if vm.poll() is None:
            vm.kill()
