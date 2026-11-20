"""Select the trial once in the EFI menu, then let its real default run after reset."""
import os
import re
import select
import subprocess
import sys
import time
from pathlib import Path

qemu, bios, out = map(Path, sys.argv[1:4])
scenario = sys.argv[4]
reasons = {"absent": "Matching y700-test-root partition unavailable",
           "wrong-identity": "Unexpected image identity"}
expected_error = f"y700-sd-trial: {reasons[scenario]}; rebooting to the default entry".encode()
libs = qemu / "usr/lib/x86_64-linux-gnu"
env = dict(os.environ, LD_LIBRARY_PATH=str(libs), QEMU_MODULE_DIR=str(libs / "qemu"))
cmd = [str(qemu / "usr/bin/qemu-system-aarch64"), "-L", str(qemu / "usr/share/qemu"),
       "-machine", "virt,gic-version=3", "-cpu", "max", "-m", "2048", "-smp", "2",
       "-nodefaults", "-no-user-config", "-display", "none", "-nic", "none",
       "-monitor", "none", "-serial", "stdio", "-bios", str(bios)]
for name, sector in ([("internal.img", 4096), ("wrong-card.img", 512)]
                     if scenario == "wrong-identity" else [("internal.img", 4096)]):
    disk = Path(name).stem
    cmd += ["-drive", f"file={name},format=raw,if=none,id={disk},snapshot=on",
            "-device", f"virtio-blk-device,drive={disk},logical_block_size={sector},physical_block_size={sector}"]

proc = subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
def send(data):
    proc.stdin.write(data)
    proc.stdin.flush()

window = b""
stage = "reset"
boots = 0
binary = b"virtio scan; for d in 0 1; do if part number virtio ${d} linux-boot bootpart; then if fatload virtio ${d}:${bootpart} ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; then bootefi ${kernel_addr_r}; fi; fi; done\r"
log = out / (scenario + ".serial")
try:
    deadline = time.monotonic() + 290
    with log.open("xb") as f:
        while time.monotonic() < deadline:
            if not select.select([proc.stdout], [], [], 1)[0]:
                continue
            data = os.read(proc.stdout.fileno(), 65536)
            if not data:
                break
            f.write(data)
            f.flush()
            window = (window + data)[-65536:]
            if b"Kernel panic - not syncing:" in window:
                raise RuntimeError(f"{scenario}: kernel halted in {stage}, see {log}")
            if b"\x1b[6n" in data:
                send(b"\x1b[25;80R")
            if stage == "reset" and b"autoboot" in window.lower():
                boots += 1
                send(b"\r")
                stage, window = "prompt", b""
            elif stage == "prompt" and b"=> " in window:
                send(binary)
                stage, window = ("menu" if boots == 1 else "default"), b""
            elif stage == "menu":
                # Two Linux entries precede automatically generated firmware actions.
                titles = [b"Debian 13 Xfce", b"Y700 candidate (microSD)"]
                if all(title in window for title in titles):
                    slot = 1 if window.index(titles[1]) < window.index(titles[0]) else 2
                    send(str(slot).encode() + b"\r")
                    stage, window = "failure", b""
            elif stage == "failure" and expected_error in window:
                print(f"{scenario}: {expected_error.decode()}", flush=True)
                stage, window = "reset", b""
            elif stage == "default" and re.search(rb"SD_TRIAL_RETURN_BASELINE_PASS pid1=1 root=internal original_kernel_notes=[0-9a-f]{64} entry=debian.conf", window):
                stage = "poweroff"
        else:
            raise TimeoutError(f"{scenario}: {stage}, see {log}")
    if stage != "poweroff" or boots != 2 or proc.wait(timeout=15) != 0:
        raise RuntimeError(f"{scenario}: incomplete return in {stage} after {boots} boots, see {log}")
    print(f"SD_TRIAL_RETURN_PASS case={scenario} boots={boots} default=debian.conf pid1=1 qemu_exit=0", flush=True)
finally:
    if proc.poll() is None:
        proc.kill()
    proc.wait()
