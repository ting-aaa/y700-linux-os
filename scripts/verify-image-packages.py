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
parser.add_argument('--qcam-lock', type=Path, help='Use this qcam build input lock for a sealed image')
parser.add_argument('--sealed-blueman-y7001', action='store_true',
                    help='Require the historical Blueman lock when verifying a sealed build')
platform = parser.add_mutually_exclusive_group()
platform.add_argument('--sealed-dev12-5', action='store_true',
                      help='Require the original dev12.5 platform and historical Blueman')
platform.add_argument('--platform-version', help='Require the specified platform version for a sealed build')
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--camera-lock', type=Path, help='Require this exact camera layer receipt')
mode.add_argument('--check-upgrade', choices=('blueman', 'onboard', 'xorg-dsi'),
                  help='Check replacement-package parents before the offline upgrade')
args = parser.parse_args()

repo = Path(__file__).resolve().parents[1]
old_blueman = repo / 'config/sealed/blueman-y7001.lock.json'
blueman_lock = old_blueman if args.sealed_dev12_5 or args.sealed_blueman_y7001 else repo / 'config/blueman.lock.json'
wanted = set()
for name in ('debian-base.lock.json', 'desktop-repair-auth.lock.json'):
    packages = json.loads((repo / 'config' / name).read_text())['packages']
    wanted.update(map(package_tuple, packages))
output = subprocess.check_output(['dpkg-query', f'--admindir={args.root}/var/lib/dpkg',
                                  '-W', '-f=${Package}\\t${Version}\\t${Architecture}\\t${db:Status-Status}\\n'], text=True)
status = {tuple(fields[:3]): fields[3] for fields in (row.split('\t') for row in output.splitlines())}
actual = {package for package, state in status.items() if state == 'installed'}
if args.check_upgrade:
    path = blueman_lock if args.check_upgrade == 'blueman' else repo / 'config' / f'{args.check_upgrade}.lock.json'
    lock = json.loads(path.read_text())
    candidates = {(p['package'], p['architecture']): package_tuple(p) for p in lock['packages']}
    for parent in replacements(lock):
        package, _, arch = parent
        if parent not in wanted:
            raise SystemExit(f'{args.check_upgrade} parent differs from the locked Debian base: {parent}')
        # dpkg can be interrupted after unpacking the candidate and before configuration.
        candidate_state = status.get(candidates[package, arch])
        if args.check_upgrade == 'blueman' and blueman_lock != old_blueman:
            previous = json.loads(old_blueman.read_text())
            if package_tuple(previous['packages'][0]) in actual:
                receipt = args.root / 'var/lib/y700/build/blueman.lock.json'
                if receipt.is_symlink() or not receipt.is_file() or json.loads(receipt.read_text()) != previous:
                    raise SystemExit('Previous Blueman package requires its sealed y7001 receipt')
                continue
        if parent not in actual and candidate_state not in (
                'installed', 'half-installed', 'unpacked', 'half-configured', 'triggers-awaited', 'triggers-pending'):
            raise SystemExit(f'Unexpected installed {package}:{arch} version for {args.check_upgrade}')
    raise SystemExit(0)
control = (repo / 'packaging/control').read_text().splitlines()
version = args.platform_version or next(line.split()[1] for line in control if line.startswith('Version: '))
if args.sealed_dev12_5:
    version = '0.1.0~dev12.5'
elif (args.sealed_blueman_y7001 and not args.platform_version
      and ('y700-platform', '0.1.0~dev12.6', 'all') in actual):
    # Keep the documented legacy invocation for the two dev12.6-platform roots.
    # Selecting a Blueman archive on a newer root preserves that root's platform.
    version = '0.1.0~dev12.6'
wanted.add(('y700-platform', version, 'all'))
platform_receipt = args.root / 'var/lib/y700/build/platform.lock.json'
if platform_receipt.is_symlink() or (platform_receipt.exists() and not platform_receipt.is_file()):
    raise SystemExit('Platform receipt must be a regular file')
if version in ('0.1.0~dev12.5', '0.1.0~dev12.6'):
    if platform_receipt.exists():
        raise SystemExit('Unexpected platform receipt for the sealed platform version')
else:
    platform_lock = json.loads((repo / 'config/platform.lock.json').read_text())
    if (not platform_receipt.exists() or json.loads(platform_receipt.read_text()) != platform_lock
            or [package_tuple(p) for p in platform_lock['packages']] != [('y700-platform', version, 'all')]):
        raise SystemExit('Platform receipt is missing or differs from the build input lock')
for layer in ('firstboot-touch', 'firstboot-drm', 'warm-greeter', 'touch-lock', 'power-desktop', 'ssc', 'blueman', 'onboard', 'chinese-ime', 'xorg-dsi',
              'camera-qcam', 'camera-pipewire', 'camera-portal'):
    name = f'{layer}.lock.json'
    receipt = args.root / 'var/lib/y700/build' / name
    if receipt.is_symlink() or (receipt.exists() and not receipt.is_file()):
        raise SystemExit(f'{name} receipt must be a regular file')
    if not receipt.exists():
        if layer == 'blueman' and args.sealed_blueman_y7001:
            raise SystemExit('Requested sealed Blueman layer receipt is missing')
        if layer == 'camera-qcam' and args.qcam_lock:
            raise SystemExit('Requested qcam layer receipt is missing')
        continue
    lock_path = args.qcam_lock if layer == 'camera-qcam' and args.qcam_lock else repo / 'config' / name
    if layer == 'blueman':
        lock_path = blueman_lock
    expected = json.loads(lock_path.read_text())
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

build = args.root / 'var/lib/y700/build'
media_receipt = build / 'video-player.lock.json'
media_packages = build / 'video-player-debian.lock.json'
player_update = build / 'video-player-update.lock.json'
prior_media = build / 'video-player-dev12.9.lock.json'
if any(path.exists() or path.is_symlink() for path in (media_receipt, media_packages, player_update, prior_media)):
    lock = json.loads((repo / 'config/video-player.lock.json').read_text())
    updated = player_update.exists() or player_update.is_symlink()
    if not updated and (prior_media.exists() or prior_media.is_symlink()):
        raise SystemExit('Historical player receipt lacks the update receipt')
    original = prior_media if updated else media_receipt
    if (original.is_symlink() or not original.is_file()
            or original.read_bytes() != (repo / 'config/video-player.lock.json').read_bytes()):
        raise SystemExit('Original combined player receipt differs from the sealed build input')
    if (media_packages.is_symlink() or not media_packages.is_file()
            or hashlib.sha256(media_packages.read_bytes()).hexdigest() != lock['debian_lock_sha256']):
        raise SystemExit('Debian player package receipt differs from the authenticated input')
    wanted.update(map(package_tuple, json.loads(media_packages.read_text())['packages']))
    files = lock['files'].copy()
    if updated:
        update_lock = repo / 'config/video-player-update.lock.json'
        for receipt in (media_receipt, player_update):
            if receipt.is_symlink() or not receipt.is_file() or receipt.read_bytes() != update_lock.read_bytes():
                raise SystemExit(f'{receipt.name} differs from the sealed player update lock')
        ledger = build / 'packages.tsv'
        # ${binary:Package} depends on the native architecture of dpkg-query.
        # Pin the ledger produced inside the ARM64 root. The independent
        # ${Package} tuple check below works on either architecture.
        ledger_digest = '5e820094693eca3db71affff0a7845f489c60ed5d556b76d62664c1b3b325dce'
        if ledger.is_symlink() or not ledger.is_file() or hashlib.sha256(ledger.read_bytes()).hexdigest() != ledger_digest:
            raise SystemExit('Sealed player update package ledger differs from the ARM64 inventory')
        update = json.loads(update_lock.read_text())
        for original in replacements(update):
            if original not in wanted:
                raise SystemExit(f'Player update parent differs from the locked media layer: {original}')
            wanted.remove(original)
        wanted.update(map(package_tuple, update['packages']))
        files.update(update['files'])
    for name, digest in files.items():
        file = args.root / name
        if file.is_symlink() or not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
            raise SystemExit(f'Player file differs from the build input: {name}')

if wanted != actual:
    raise SystemExit(f'Package mismatch: missing={sorted(wanted-actual)} extra={sorted(actual-wanted)}')
records = ''.join('\t'.join(record) + '\n' for record in sorted(actual))
print(f'package_count={len(actual)}')
print(f'package_digest={hashlib.sha256(records.encode()).hexdigest()}')
