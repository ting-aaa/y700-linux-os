"""Exercise candidate enrollment and the normal Xfce greeter in a disposable VM.

Run through uv after the two-disk EFI test. The card is opened with QEMU
snapshot=on. Only a new private working directory persists after this test.
"""
import argparse
import os
import re
import secrets
import select
import socket
import subprocess
import threading
import time
from pathlib import Path


def drain_monitor(sock):
    # HMP echoes keyboard commands. Consume replies to keep the socket writable.
    try:
        while sock.recv(65536):
            pass
    except OSError:
        pass


def type_keys(monitor, value):
    for key in [*value, 'ret']:
        monitor.sendall(f'sendkey {key} 110\n'.encode())
        time.sleep(.28)


class Serial:
    def __init__(self, process):
        self.process = process
        self.pending = b''

    def send(self, value):
        self.process.stdin.write(value.encode() + b'\r')
        self.process.stdin.flush()

    def wait(self, pattern, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = re.search(pattern, self.pending, re.I)
            if match:
                self.pending = self.pending[match.end():]
                return
            if select.select([self.process.stdout], [], [], 1)[0]:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('VM exited before reaching the expected state')
                self.pending = (self.pending + chunk)[-65536:]
        raise TimeoutError(f'Guest did not reach {pattern!r}')


def test_login(serial, identity):
    serial.wait(b'autoboot')
    serial.send('')
    serial.wait(rb'=> ')
    serial.send('virtio scan; for d in 0 1; do if part number virtio ${d} linux-boot bootpart; '
                'then if fatload virtio ${d}:${bootpart} ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI; '
                'then bootefi ${kernel_addr_r}; fi; fi; done')
    serial.wait(rb'Starting [^\r\n]*y700-firstboot\.service', 180)
    password = secrets.token_hex(10)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
        monitor.connect('monitor.sock')
        threading.Thread(target=drain_monitor, args=(monitor,), daemon=True).start()
        try:
            time.sleep(5)
            type_keys(monitor, password)
            time.sleep(3)
            type_keys(monitor, password)
            time.sleep(4)
            serial.send('')
            serial.wait(rb'y700-linux login:')
            serial.send('y700')
            serial.wait(rb'Password:')
            serial.send(password)
            serial.wait(rb'y700@y700-linux:[^\r\n]*\$')
            serial.send(f'test "$(cat /etc/y700/image-id)" = {identity} && '
                        'test -e /etc/y700/user-configured && test "$(id -un)" = y700 && '
                        'systemctl is-active --quiet lightdm && printf "ENROLL_%s\\n" OK')
            serial.wait(rb'[\r\n]ENROLL_OK[\r\n]')
            print('PASS: first-boot enrollment and authenticated y700 console login.', flush=True)
            serial.send("for i in $(seq 1 35); do if pgrep -f '^/usr/sbin/lightdm-gtk-greeter' >/dev/null; "
                        "then printf 'GREETER_%s\\n' READY; break; fi; sleep 1; done")
            serial.wait(rb'[\r\n]GREETER_READY[\r\n]', 50)
            time.sleep(10)
            type_keys(monitor, 'y700')
            time.sleep(2)
            type_keys(monitor, password)
            serial.send("for i in $(seq 1 75); do if pgrep -xu y700 xfce4-session >/dev/null && "
                        "pgrep -xu y700 xfwm4 >/dev/null && pgrep -xu y700 xfce4-panel >/dev/null && "
                        "pgrep -xu y700 xfdesktop >/dev/null; then printf 'DESKTOP_%s\\n' READY; "
                        "break; fi; sleep 1; done")
            serial.wait(rb'[\r\n]DESKTOP_READY[\r\n]', 90)
            print('PASS: graphical login, Xfce session, window manager, panel and desktop as y700.', flush=True)
        finally:
            monitor.shutdown(socket.SHUT_RDWR)


def run(args):
    paths = [Path(p).resolve(strict=True) for p in (args.images, args.board, args.qemu, args.split_vm, args.card)]
    images, board, bundle, split_vm, card = paths
    subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=card, check=True)
    identity = (images/'identity.txt').read_text().splitlines()[0].removeprefix('image_id=')
    if not re.fullmatch(r'y700-prc-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', identity):
        raise ValueError('Invalid candidate identity')
    work = Path(args.work).resolve()
    work.mkdir(mode=0o700)
    os.chdir(work)
    subprocess.run(['cp', '--sparse=always', split_vm/'internal.gpt', 'internal.gpt'], check=True)
    spec = 'internal.gpt@@1048576'
    path = '::/loader/entries/y700-test.conf'
    entry = subprocess.check_output(['mtype', '-i', spec, path], text=True)
    options = ('options rdinit=/init root=PARTLABEL=y700-test-root rw y700.media=sd '
               'console=tty0 console=ttyAMA0 loglevel=4 systemd.show_status=yes')
    entry, count = re.subn(r'^options .+$', options, entry, flags=re.M)
    if count != 1:
        raise ValueError('Expected one loader command line')
    Path('entry.conf').write_text(entry)
    subprocess.run(['mcopy', '-o', '-i', spec, 'entry.conf', path], check=True)
    lib = bundle/'usr/lib/x86_64-linux-gnu'
    env = dict(os.environ, LD_LIBRARY_PATH=str(lib), QEMU_MODULE_DIR=str(lib/'qemu'))
    cmd = [bundle/'usr/bin/qemu-system-aarch64', '-L', bundle/'usr/share/qemu', '-machine', 'virt,gic-version=3',
           '-cpu', 'max', '-smp', '3', '-m', '2048', '-nodefaults', '-no-user-config', '-no-reboot',
           '-display', 'none', '-device', 'ramfb', '-nic', 'none', '-device', 'qemu-xhci,id=xhci',
           '-device', 'usb-kbd,bus=xhci.0', '-monitor', 'unix:monitor.sock,server=on,wait=off',
           '-serial', 'stdio', '-bios', board/'efi/qemu-uboot/u-boot.bin']
    for name, disk, sector in [('card', card/'y700-test-card.img', 512), ('internal', 'internal.gpt', 4096)]:
        cmd.extend(['-drive', f'file={disk},format=raw,if=none,id={name},snapshot=on',
                    '-device', f'virtio-blk-device,drive={name},logical_block_size={sector},physical_block_size={sector}'])
    with subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as proc:
        try:
            test_login(Serial(proc), identity)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('images', 'board', 'qemu', 'split-vm', 'card', 'work'):
        parser.add_argument('--' + name, required=True)
    run(parser.parse_args())
