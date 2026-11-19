"""Validate reviewed SSC inputs and copy them only when given a staging directory."""

import argparse
import hashlib
import json
import re
import shutil
import stat
import struct
import subprocess
import tarfile
from pathlib import Path


FIRMWARE_SHA256 = '4449c804f27c3d3e2e2e52870923a6567adb6ed75b5d739ec6707e9344239137'
FIRMWARE_DIR = 'usr/lib/firmware/qcom/sm8475/lenovo/tb320fc/'


def private(path, directory=False):
    info = path.lstat()
    test = stat.S_ISDIR if directory else stat.S_ISREG
    if not test(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError(f'Expected a root-owned, non-writable-by-others input: {path}')


def registry_digest(state):
    private(state, directory=True)
    registry = state / 'registry'
    private(registry, directory=True)
    groups = registry / 'registry'
    private(groups, directory=True)
    files = sorted(groups.iterdir())
    if not 329 <= len(files) <= 512:
        raise ValueError('Unexpected SSC registry group count')
    version = registry / 'sns_reg_version'
    receipt = registry / '.y700-factory-calibration.json'
    expected = {groups, version, receipt}
    if set(registry.iterdir()) != expected:
        raise ValueError('Unexpected files in SSC registry parent')
    digest = hashlib.sha256()
    for path in [version, receipt, *files]:
        private(path)
        if not re.fullmatch(r'[a-zA-Z0-9_.-]+', path.name) or not 0 < path.stat().st_size <= 262144:
            raise ValueError('Unexpected SSC registry filename or file size')
        raw = path.read_bytes()
        digest.update(f'{path.relative_to(registry).as_posix()}\t{hashlib.sha256(raw).hexdigest()}\n'.encode())
    if version.read_bytes() != b'version=7\0':
        raise ValueError('SSC registry requires version 7')
    record = json.loads(receipt.read_text())
    if record.get('format') != 1 or record.get('registry_version') != 7 or not record.get('factory_groups', 0) > 0:
        raise ValueError('SSC registry requires the reviewed factory calibration receipt')
    return digest.hexdigest()


def split_firmware(package):
    private(package)
    if package.stat().st_size != 2959926:
        raise ValueError('CN350 archive size differs from reference')
    with package.open('rb') as archive:
        if hashlib.file_digest(archive, 'sha256').hexdigest() != FIRMWARE_SHA256:
            raise ValueError('CN350 archive differs from the pinned split firmware package')
    files = {}
    with subprocess.Popen(['dpkg-deb', '--fsys-tarfile', package], stdout=subprocess.PIPE) as pipe:
        with tarfile.open(fileobj=pipe.stdout, mode='r|') as contents:
            for member in contents:
                name = member.name.removeprefix('./').removeprefix(FIRMWARE_DIR)
                if not re.fullmatch(r'slpi\.(?:mdt|b[0-9]{2})', name):
                    continue
                if name in files or not member.isfile() or member.size <= 0:
                    raise ValueError('Invalid split firmware archive member')
                files[name] = contents.extractfile(member).read()
        pipe.stdout.read()
        if pipe.wait():
            raise ValueError('Failed to read the firmware package')
    if files.keys() != {'slpi.mdt', *(f'slpi.b{index:02d}' for index in range(24) if index != 22)}:
        raise ValueError('Unexpected SLPI MDT and split firmware set')
    return files


def check_load_ranges(files, base, size):
    data = files['slpi.mdt']
    if len(data) < 52 or data[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('Expected the ELF32 SLPI MDT')
    machine = struct.unpack_from('<H', data, 18)[0]
    offset = struct.unpack_from('<I', data, 28)[0]
    stride, count = struct.unpack_from('<HH', data, 42)
    if machine != 164 or stride != 32 or count != 24 or offset + stride * count > len(data):
        raise ValueError('Unexpected SLPI program-header table')
    ranges = []
    backed = 0
    for index in range(count):
        kind, _, _, addr, file_len, mem_len, flags, _ = struct.unpack_from('<8I', data, offset + index * stride)
        if kind != 1 or not mem_len or flags & (7 << 24) == (2 << 24):
            continue
        if file_len > mem_len or (file_len and len(files.get(f'slpi.b{index:02d}', b'')) != file_len):
            raise ValueError('SLPI program-header length differs from a split segment')
        backed += bool(file_len)
        ranges.append((addr, addr + mem_len, bool(flags & (1 << 27))))
    if backed != 21:
        raise ValueError('Unexpected SLPI file-backed segment count')
    low, high = min(item[0] for item in ranges), max(item[1] for item in ranges)
    if any(item[2] for item in ranges):
        fits = high - low <= size
    else:
        fits = low >= base and high <= base + size
    if not fits:
        raise ValueError('SLPI segments exceed the live DT carveout')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('state', type=Path)
    parser.add_argument('--package', type=Path)
    parser.add_argument('--state-sha256')
    parser.add_argument('--dt-node', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    found = registry_digest(args.state)
    if not args.package:
        if args.state_sha256 or args.dt_node or args.output:
            parser.error('Firmware verification requires the package, state digest and live DT node')
        print(found)
        return
    if found != args.state_sha256 or not args.dt_node:
        raise ValueError('SSC registry digest or live DT input differs from the reviewed input')
    files = split_firmware(args.package)
    phandle = (args.dt_node / 'memory-region').read_bytes()
    reserved = Path('/sys/firmware/devicetree/base/reserved-memory')
    regions = [entry.parent for entry in reserved.glob('*/phandle') if entry.read_bytes() == phandle]
    if len(phandle) != 4 or len(regions) != 1:
        raise ValueError('Expected one live SLPI carveout')
    base, size = struct.unpack('>QQ', (regions[0] / 'reg').read_bytes())
    check_load_ranges(files, base, size)
    if args.output:
        firmware = args.output / 'firmware'
        for name, data in files.items():
            with (firmware / name).open('xb') as output:
                output.write(data)
        snapshot = args.output / 'state'
        shutil.copytree(args.state / 'registry', snapshot / 'registry')
        if registry_digest(snapshot) != found:
            raise ValueError('SSC registry changed while taking its private snapshot')
    print('Verified CN350 split firmware, live SLPI ranges and calibrated registry snapshot.')


if __name__ == '__main__':
    main()
