"""Start a network-isolated QEMU virt guest and validate its serial result."""
import os
import re
import select
import subprocess
import sys
import time
from pathlib import Path

bundle, bios, vm = map(Path, sys.argv[1:4])
label, sector = sys.argv[5:7]
if (label, sector) not in {('linux-boot', '4096'), ('y700-test-esp', '512')}:
    raise ValueError('Unsupported test media')
split = sys.argv[7] == '1'
package_count = str(int(sys.argv[8])).encode()
expected = re.compile(b'Y700_BOOT_PASS image=' + re.escape(sys.argv[4].encode()) +
                      rb' root=/dev/(?P<disk>vd[ab])2 esp=/dev/(?P=disk)1 '
                      rb'kernel=7\.3\.4-asphalt-prc pid1=systemd packages=' + package_count +
                      rb' split=' + str(int(split)).encode())
lib = bundle / 'usr/lib/x86_64-linux-gnu'
env = dict(os.environ, LD_LIBRARY_PATH=str(lib), QEMU_MODULE_DIR=str(lib / 'qemu'))
args = [bundle / 'usr/bin/qemu-system-aarch64', '-L', bundle / 'usr/share/qemu',
        '-machine', 'virt,gic-version=3', '-cpu', 'max', '-smp', '3', '-m', '2048',
        '-nodefaults', '-no-user-config', '-display', 'none', '-nic', 'none',
        '-monitor', 'none', '-serial', 'stdio', '-bios', bios, '-no-reboot',
        '-drive', f'file={vm}/disk.gpt,format=raw,if=none,id=disk,snapshot=on',
        '-device', f'virtio-blk-device,drive=disk,logical_block_size={sector},physical_block_size={sector}']
if split:
    label = 'linux-boot'
    args += ['-drive', f'file={vm}/internal.gpt,format=raw,if=none,id=internal,snapshot=on',
             '-device', 'virtio-blk-device,drive=internal,logical_block_size=4096,physical_block_size=4096']
with (vm / 'serial.log').open('xb', buffering=0) as log:
    proc = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    phase = 'reset'
    recent = b''
    loader = efi_runtime = powered_down = False
    selected = not split
    passed = None
    try:
        deadline = time.monotonic() + 360
        while time.monotonic() < deadline:
            if not select.select([proc.stdout], [], [], 2)[0]:
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            log.write(chunk)
            recent = (recent + chunk)[-65536:]
            if phase == 'reset' and b'autoboot' in recent.lower():
                proc.stdin.write(b'\r')
                proc.stdin.flush()
                phase = 'firmware'
            if phase == 'firmware' and b'=> ' in recent:
                proc.stdin.write(b'virtio scan; for d in 0 1; do ' +
                                 f'if part number virtio ${{d}} {label} bootpart; then '.encode() +
                                 b'if fatload virtio ${d}:${bootpart} ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; '
                                 b'then bootefi ${kernel_addr_r}; fi; fi; done\r')
                proc.stdin.flush()
                phase = 'guest'
            if phase == 'guest':
                loader |= b'Booting /\\EFI\\BOOT\\BOOTAA64.EFI' in recent
                selected |= b'Y700_VM_EFI_ENTRY selected=y700-test.conf loader_esp=internal' in recent
                efi_runtime |= b'efi: EFI v' in recent and b'by Das U-Boot' in recent
                powered_down |= b'reboot: Power down' in recent
                if passed is None and (match := expected.search(recent)):
                    passed = match.group().decode()
                    print(passed, flush=True)
        else:
            raise TimeoutError(f'EFI boot timed out in {phase}, see serial.log')
        if passed is None:
            raise RuntimeError(f'Guest exited in {phase} without the required serial evidence')
        if not (loader and selected and efi_runtime and powered_down) or proc.wait(timeout=10) != 0:
            raise RuntimeError('Guest did not load the expected EFI menu payload and power off cleanly')
        print('Y700_VM_EFI_SELECTION uboot_efi=1 poweroff=1 qemu_exit=0', flush=True)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
