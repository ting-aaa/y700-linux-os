"""Exercise the Xorg replacement layer with real dpkg-query and a disposable status database."""
import json
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

repo = Path(__file__).resolve().parents[1]
config = repo / 'config'
checker = repo / 'scripts/verify-image-packages.py'


def load(layer):
    return json.loads((config / f'{layer}.lock.json').read_text())


def verify(root, *options, error=None):
    result = subprocess.run([sys.executable, checker, root, *options], text=True, capture_output=True)
    if error is None:
        result.check_returncode()
    elif result.returncode == 0 or error not in result.stderr:
        raise AssertionError(f'Expected {error!r}, got {result.returncode}: {result.stderr}')
    return result.stdout


def write_status(root, packages, states=None):
    states = states or {}
    (root / 'var/lib/dpkg/status').write_text(''.join(
        f'Package: {name}\nVersion: {version}\nArchitecture: {arch}\n'
        f'Status: install ok {states.get((name, arch), "installed")}\n'
        'Maintainer: Test <test@example.invalid>\nDescription: Test fixture\n\n'
        for (name, arch), version in sorted(packages.items())))


with TemporaryDirectory() as directory:
    root = Path(directory)
    receipts = root / 'var/lib/y700/build'
    receipts.mkdir(parents=True)
    (root / 'var/lib/dpkg').mkdir()
    db = {}
    # Model a complete combined image. Newer package versions replace rows by Debian identity.
    for layer in ('debian-base', 'desktop-repair-auth', 'firstboot-touch', 'firstboot-drm', 'warm-greeter',
                  'ssc', 'blueman', 'chinese-ime', 'camera-qcam', 'camera-pipewire', 'camera-portal', 'camera-layer'):
        for p in load(layer)['packages']:
            db[p['package'], p['architecture']] = p['version']
        if layer not in ('debian-base', 'desktop-repair-auth'):
            shutil.copyfile(config / f'{layer}.lock.json', receipts / f'{layer}.lock.json')
    control = (repo / 'packaging/control').read_text().splitlines()
    db['y700-platform', 'all'] = next(line.split()[1] for line in control if line.startswith('Version: '))
    write_status(root, db)
    before = verify(root)
    verify(root, '--check-upgrade', 'blueman')
    upgrade = ('--check-upgrade', 'xorg-dsi')
    verify(root, *upgrade)

    lock = load('xorg-dsi')
    for p in lock['replaces']:
        key = (p['package'], p['architecture'])
        assert db[key] == p['version']
        write_status(root, {**db, key: '1:0.0'})
        verify(root, *upgrade, error=f'Unexpected installed {key[0]}:{key[1]}')
    write_status(root, {**db, ('blueman', 'arm64'): '1.0'})
    verify(root, '--check-upgrade', 'blueman', error='Unexpected installed blueman:arm64')

    receipt = receipts / 'xorg-dsi.lock.json'
    shutil.copyfile(config / receipt.name, receipt)
    for i, p in enumerate(lock['packages']):
        key = (p['package'], p['architecture'])
        db[key] = p['version']
        write_status(root, db, {key: 'unpacked'})
        verify(root, *upgrade)
        verify(root, error='Package mismatch')
        write_status(root, db, {key: 'config-files'})
        verify(root, *upgrade, error='Unexpected installed')
        write_status(root, db)
        verify(root, *upgrade)
        if i == 0:
            verify(root, error='Package mismatch')
    after = verify(root)
    assert after == verify(root)
    assert before.splitlines()[0] == after.splitlines()[0] and before != after
    receipt.unlink()
    verify(root, error='Package mismatch')
    lock['packages'][0]['sha256'] = '0' * 64
    receipt.write_text(json.dumps(lock))
    verify(root, error='receipt differs')
    print(f'Before optional Xorg layer:\n{before}After optional Xorg layer:\n{after}', end='')
    print('XORG_DSI_LAYER_LOCK_PASS')
