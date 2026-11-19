"""Compare the ARM64 package database of an integrated build root to the input locks."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from camera_layer import RECEIPT, load_camera_lock

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
parser.add_argument('--camera-lock', type=Path, help='Require this exact camera layer receipt')
args = parser.parse_args()

repo = Path(__file__).resolve().parents[1]
wanted = set()
for name in ('debian-base.lock.json', 'desktop-repair-auth.lock.json'):
    packages = json.loads((repo / 'config' / name).read_text())['packages']
    wanted.update((p['package'], p['version'], p['architecture']) for p in packages)
control = (repo / 'packaging/control').read_text().splitlines()
version = next(line.split()[1] for line in control if line.startswith('Version: '))
wanted.add(('y700-platform', version, 'all'))
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

output = subprocess.check_output(['dpkg-query', f'--admindir={args.root}/var/lib/dpkg',
                                  '-W', '-f=${Package}\\t${Version}\\t${Architecture}\\t${db:Status-Status}\\n'], text=True)
actual = {tuple(row.split('\t')[:3]) for row in output.splitlines() if row.endswith('\tinstalled')}
if wanted != actual:
    raise SystemExit(f'Package mismatch: missing={sorted(wanted-actual)} extra={sorted(actual-wanted)}')
records = ''.join('\t'.join(record) + '\n' for record in sorted(actual))
print(f'package_count={len(actual)}')
print(f'package_digest={hashlib.sha256(records.encode()).hexdigest()}')
