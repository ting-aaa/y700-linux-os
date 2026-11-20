"""Compare the ARM64 package database of an integrated build root to the input locks."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from camera_layer import RECEIPT, load_camera_lock


def package_tuple(p):
    return (p['package'], p['version'], p['architecture'])


def replacements(lock):
    # The existing single-package Blueman receipt uses an object.
    entries = lock.get('replaces', [])
    if isinstance(entries, dict):
        entries = [entries]
    return [package_tuple(p) for p in entries]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--camera-lock', type=Path, help='Require this exact camera layer receipt')
mode.add_argument('--check-upgrade', choices=('blueman', 'onboard', 'xorg-dsi'),
                  help='Check replacement-package parents before the offline upgrade')
args = parser.parse_args()

repo = Path(__file__).resolve().parents[1]
wanted = set()
for name in ('debian-base.lock.json', 'desktop-repair-auth.lock.json'):
    packages = json.loads((repo / 'config' / name).read_text())['packages']
    wanted.update(map(package_tuple, packages))
output = subprocess.check_output(['dpkg-query', f'--admindir={args.root}/var/lib/dpkg',
                                  '-W', '-f=${Package}\\t${Version}\\t${Architecture}\\t${db:Status-Status}\\n'], text=True)
status = {tuple(fields[:3]): fields[3] for fields in (row.split('\t') for row in output.splitlines())}
actual = {package for package, state in status.items() if state == 'installed'}
if args.check_upgrade:
    lock = json.loads((repo / 'config' / f'{args.check_upgrade}.lock.json').read_text())
    candidates = {(p['package'], p['architecture']): package_tuple(p) for p in lock['packages']}
    for parent in replacements(lock):
        package, _, arch = parent
        if parent not in wanted:
            raise SystemExit(f'{args.check_upgrade} parent differs from the locked Debian base: {parent}')
        # dpkg can be interrupted after unpacking the candidate and before configuration.
        candidate_state = status.get(candidates[package, arch])
        if parent not in actual and candidate_state not in (
                'installed', 'half-installed', 'unpacked', 'half-configured', 'triggers-awaited', 'triggers-pending'):
            raise SystemExit(f'Unexpected installed {package}:{arch} version for {args.check_upgrade}')
    raise SystemExit(0)
control = (repo / 'packaging/control').read_text().splitlines()
version = next(line.split()[1] for line in control if line.startswith('Version: '))
wanted.add(('y700-platform', version, 'all'))
for layer in ('firstboot-touch', 'firstboot-drm', 'warm-greeter', 'ssc', 'blueman', 'onboard', 'chinese-ime', 'xorg-dsi',
              'camera-qcam', 'camera-pipewire', 'camera-portal'):
    name = f'{layer}.lock.json'
    receipt = args.root / 'var/lib/y700/build' / name
    if receipt.is_symlink() or (receipt.exists() and not receipt.is_file()):
        raise SystemExit(f'{name} receipt must be a regular file')
    if not receipt.exists():
        continue
    expected = json.loads((repo / 'config' / name).read_text())
    if json.loads(receipt.read_text()) != expected:
        raise SystemExit(f'{name} receipt differs from the build input lock')
    for original in replacements(expected):
        if original not in wanted:
            raise SystemExit(f'{layer} parent differs from the locked Debian base: {original}')
        wanted.remove(original)
    wanted.update(map(package_tuple, expected['packages']))
camera_receipt = args.root / RECEIPT
if camera_receipt.is_symlink():
    raise SystemExit('Camera layer receipt must be a regular file')
if camera_receipt.exists():
    camera_packages = load_camera_lock(camera_receipt)
    if args.camera_lock and camera_packages != load_camera_lock(args.camera_lock):
        raise SystemExit('Integrated camera receipt differs from the requested camera lock')
    wanted.update((p['package'], p['version'], p['architecture']) for p in camera_packages)
elif args.camera_lock:
    raise SystemExit('Integrated camera layer receipt is missing')

if wanted != actual:
    raise SystemExit(f'Package mismatch: missing={sorted(wanted-actual)} extra={sorted(actual-wanted)}')
records = ''.join('\t'.join(record) + '\n' for record in sorted(actual))
print(f'package_count={len(actual)}')
print(f'package_digest={hashlib.sha256(records.encode()).hexdigest()}')
