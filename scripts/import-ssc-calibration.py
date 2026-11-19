#!/usr/bin/python3
"""Provision a new TB320FC_PRC SSC registry using this tablet's Android persist data."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


VERSION = b'version=7\0'
PARTITION_BYTES = 32 * 1024 * 1024
FACTORY = '/sensors/registry'
RECEIPT = '.y700-factory-calibration.json'
NAME = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,159}')
# The other Android groups configure bus routing, drivers and logical sensors.
CALIBRATION = re.compile(
    r'(?:[a-z0-9]+_[0-9]+_platform\.[a-z0-9_]+\.(?:fac_cal(?:_[0-9]+)?|custom_cal|prox_offset_hw_cal)'
    r'|aw9610x_[0-9]+_sar\.cali'
    r'|sns_gyro_cal_(?:persist|table)_s[0-9]+'
    r'|sns_mag_cal_persist_s[0-9]+c[0-9]+)(?:\.[A-Za-z0-9_]+)*'
)


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def plain_path(path):
    path = path.absolute()
    if '..' in path.parts or any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError('Expected a direct path without symlinks or parent traversal')
    return path


def backup_image(root):
    root = plain_path(root)
    manifest = json.loads(plain_path(root/'manifest.json').read_text())
    audit = json.loads(plain_path(root/'partition_verification.json').read_text())
    identity = manifest['device_identity'].splitlines()
    if ('TB320FC' not in identity or not any('TB320FC_CN_' in line and '.350_' in line for line in identity)
            or manifest['schema_version'] != 2 or audit['status'] != 'verified'
            or not manifest['serial'] or audit['serial'] != manifest['serial']):
        raise ValueError('Backup identity does not match the supported TB320FC CN350 capture')
    entries = [row for row in manifest['results'] if row['name'] == 'persist']
    if len(entries) != 1:
        raise ValueError('Backup must contain exactly one persist manifest entry')
    entry = entries[0]
    image = plain_path(root/'partitions/persist.img')
    if (not image.is_file() or image.stat().st_size != PARTITION_BYTES
            or entry['expected_bytes'] != PARTITION_BYTES or entry['written_bytes'] != PARTITION_BYTES
            or entry['device'] != '/dev/block/sda2' or entry['status'] != 'verified'
            or not entry['source_stable']):
        raise ValueError('Invalid per-device persist capture')
    digest = sha256(image)
    if any(entry[key] != digest for key in
           ('source_sha256_before', 'source_sha256_after', 'staged_sha256', 'pc_sha256')):
        raise ValueError('Per-device persist image differs from the backup capture')
    return image


def ufs_persist(blocks):
    candidates = []
    for block in blocks.iterdir():
        if ('1d84000.ufshc' in block.resolve().parts and (block/'partition').exists()
                and 'PARTNAME=persist' in (block/'uevent').read_text().splitlines()):
            candidates.append(block)
    if len(candidates) != 1:
        raise ValueError('Expected one internal UFS persist partition')
    return candidates[0]


def live_image():
    dt = Path('/proc/device-tree')
    if (b'lenovo,asphalt' not in (dt/'compatible').read_bytes().split(b'\0')
            or (dt/'region_country').read_bytes().rstrip(b'\0') != b'PRC'):
        raise ValueError('This import requires the TB320FC_PRC board')
    block = ufs_persist(Path('/sys/class/block'))
    image = Path('/dev')/block.name
    info = image.stat()
    if (not stat.S_ISBLK(info.st_mode) or int((block/'size').read_text()) * 512 != PARTITION_BYTES
            or (block/'dev').read_text().strip() != f'{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}'):
        raise ValueError('Unexpected internal persist block device')
    device = (block/'dev').read_text().strip()
    if any(row.split()[2] == device and 'rw' in row.split()[5].split(',')
           for row in Path('/proc/self/mountinfo').read_text().splitlines()):
        raise ValueError('Refusing to read an actively writable mounted persist filesystem')
    return image


def debugfs(image, command):
    # Default debugfs opens the filesystem read-only. Keep OEM error contents private.
    result = subprocess.run(['debugfs', '-R', command, str(image)], capture_output=True, check=True)
    return result.stdout


def group_bytes(name, raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f'Duplicate key in SSC group {name}')
            result[key] = value
        # Upstream's SSC parser requires these fields to precede their payload.
        order = [key for key in ('owner', 'type', 'ver', 'data') if key in result]
        return {key: result[key] for key in dict.fromkeys(order + list(result))}

    group = json.loads(raw, object_pairs_hook=unique)
    if (not isinstance(group, dict) or list(group) != [name] or not isinstance(group[name], dict)
            or not isinstance(group[name].get('owner'), str)):
        raise ValueError(f'Invalid SSC group {name}')
    return (json.dumps(group, separators=(',', ':'), allow_nan=False) + '\n').encode()


def factory_groups(image):
    if debugfs(image, f'cat {FACTORY}/sns_reg_version') != VERSION:
        raise ValueError('Factory registry version differs from the TB320FC v7 seed')
    groups = {}
    entries = debugfs(image, f'ls -p {FACTORY}/registry').decode().splitlines()
    for line in entries:
        if not line:
            continue
        _, _, mode, _, _, name, length, end = line.split('/')
        if name in ('.', '..'):
            continue
        if end or not NAME.fullmatch(name) or not stat.S_ISREG(int(mode, 8)):
            raise ValueError('Invalid entry in the factory registry directory')
        if not CALIBRATION.fullmatch(name):
            continue
        if name in groups or not 0 < int(length) <= 65536 or len(groups) >= 1024:
            raise ValueError('Invalid factory calibration group count or size')
        data = debugfs(image, f'cat {FACTORY}/registry/{name}')
        if len(data) != int(length):
            raise ValueError(f'Incomplete factory group {name}')
        groups[name] = group_bytes(name, data)
    if not groups:
        raise ValueError('No supported calibration groups in the factory partition')
    return groups


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def provision(seed, state, groups):
    seed, state = plain_path(seed), plain_path(state)
    if state.is_relative_to(seed) or seed.is_relative_to(state):
        raise ValueError('Keep the private writable state separate from the packaged seed')
    if (plain_path(seed/'sns_reg_version').read_bytes() != VERSION
            or not plain_path(seed/'registry').is_dir() or not groups):
        raise ValueError('Expected the installed v7 board seed and factory calibration')
    base = {}
    for path in (seed/'registry').iterdir():
        if path.is_symlink() or not path.is_file() or not NAME.fullmatch(path.name):
            raise ValueError('Invalid entry in board seed')
        data = path.read_bytes()
        group_bytes(path.name, data)
        base[path.name] = data
    if not base or set(seed.iterdir()) != {seed/'registry', seed/'sns_reg_version'}:
        raise ValueError('Unexpected board seed layout')
    fingerprint = hashlib.sha256()
    for name, data in sorted(groups.items()):
        fingerprint.update(name.encode() + b'\0' + hashlib.sha256(data).digest())
    receipt = {'format': 1, 'registry_version': 7, 'factory_groups': len(groups),
               'factory_group_digest': fingerprint.hexdigest()}
    state.mkdir(mode=0o750, exist_ok=True)
    if state.stat().st_uid != os.geteuid() or state.stat().st_mode & 0o022:
        raise ValueError('State directory must be owned by this account and privately writable')
    lock = os.open(state/'.seed.lock', os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(lock).st_mode):
            raise ValueError('Invalid SSC seed lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        target = plain_path(state/'registry')
        if target.exists():
            previous = plain_path(target/RECEIPT)
            if previous.is_file() and json.loads(previous.read_text()) == receipt:
                return 'Calibration was already imported. Existing sensor state retained.'
            raise ValueError('Existing sensor state retained. Import into a new private state directory.')
        with tempfile.TemporaryDirectory(prefix='.import-', dir=state) as temporary:
            stage = Path(temporary)/'registry'
            output = stage/'registry'
            stage.mkdir(mode=0o700)
            output.mkdir(mode=0o700)
            for name, data in (base | groups).items():
                write_private(output/name, data)
            write_private(stage/'sns_reg_version', VERSION)
            write_private(stage/RECEIPT, (json.dumps(receipt, sort_keys=True) + '\n').encode())
            sync_dir(output)
            sync_dir(stage)
            os.rename(stage, target)
            sync_dir(state)
    finally:
        os.close(lock)
    return f'Imported {len(groups)} per-device groups into a new {len(base | groups)}-group registry.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    live = sub.add_parser('import-live', help='Read this tablet’s internal factory persist partition')
    live.add_argument('--state', type=Path, default=Path('/var/lib/y700-ssc'))
    live.set_defaults(seed=Path('/usr/share/y700/ssc/seed/registry'))
    stage = sub.add_parser('stage-backup', help='Use an independently checked local backup on Linux')
    stage.add_argument('--backup', type=Path, required=True)
    stage.add_argument('--seed', type=Path, required=True, help='Private board package seed/registry directory')
    stage.add_argument('--state', type=Path, required=True, help='Per-device state on a private Linux filesystem')
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'import-live':
        if os.geteuid() != 0:
            parser.error('Native import requires root read access to the internal persist partition')
        image = live_image()
    else:
        backup, state = plain_path(args.backup), plain_path(args.state)
        if state.is_relative_to(backup) or backup.is_relative_to(state):
            parser.error('Keep the private output separate from the read-only backup')
        image = backup_image(args.backup)
    print(provision(args.seed, args.state, factory_groups(image)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
