"""Build a private TB320FC_PRC CN350 SSC firmware package from verified images."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]
SENSOR_DATA = Path('usr/share/y700/ssc')
SLPI_FIRMWARE = Path('usr/lib/firmware/qcom/sm8475/lenovo/tb320fc')
PACKAGE = 'y700-ssc-cn350-firmware'
VERSION = '17.0.350-1'
EPOCH = 1795046400  # 2026-11-19 UTC


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verified_inputs(stock):
    manifest = json.loads((REPO/'docs/research/cn350-firmware-comparison.json').read_text())
    chosen = {'modem.img': 'image', 'dsp.img': 'sdsp'}
    image_hashes = {}
    for image in chosen:
        image_hash = digest(stock/image)
        if image_hash != manifest['stock_images'][image]:
            raise ValueError(f'CN350 image hash mismatch: {image}')
        image_hashes[image] = image_hash

    files = {image: {} for image in chosen}
    for item in manifest['files']:
        image = item['image']
        if image not in chosen:
            continue
        path = PurePosixPath(item['path'])
        name = path.name
        if (path.parent.as_posix() != '/' + chosen[image] or
                not re.fullmatch(r'[A-Za-z0-9_.]+', name) or name in files[image]):
            raise ValueError(f'Invalid firmware entry: {path}')
        files[image][name] = item['stock_sha256']

    listing = subprocess.check_output(
        ['mdir', '-b', '-i', stock/'modem.img', '::/image/slpi*'], text=True)
    listed = {PurePosixPath(line.strip()).name for line in listing.splitlines() if line.strip()}
    if listed != files['modem.img'].keys() or len(listed) != 26 or len(files['dsp.img']) != 7:
        raise ValueError('Unexpected CN350 SLPI or SDSP inventory')
    return image_hashes, files


def verify_split_slpi(firmware):
    mdt = (firmware/'slpi.mdt').read_bytes()
    if len(mdt) < 52 or mdt[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('CN350 SLPI MDT is not little-endian ELF32')
    (_, machine, _, _, phoff, _, _, _, phsize, phnum, _, _, _) = struct.unpack_from(
        '<HHIIIIIHHHHHH', mdt, 16)
    if machine != 164 or phsize != 32 or phnum != 24 or phoff + phnum * phsize > len(mdt):
        raise ValueError('Unexpected CN350 Hexagon MDT program header table')
    loaded = []
    for index in range(phnum):
        ptype, _, _, _, filesz, memsz, flags, _ = struct.unpack_from(
            '<IIIIIIII', mdt, phoff + phsize * index)
        if ptype != 1 or flags & (7 << 24) == (2 << 24) or not memsz:
            continue
        if filesz > memsz:
            raise ValueError(f'Invalid SLPI segment sizes at {index}')
        if filesz:
            name = f'slpi.b{index:02d}'
            if (firmware/name).stat().st_size != filesz:
                raise ValueError(f'SLPI file length disagrees with MDT: {name}')
            loaded.append(name)
    if len(loaded) != 21:
        raise ValueError('Unexpected CN350 file-backed load segment count')
    return loaded


def extract_images(stock, stage, files):
    firmware = stage/SLPI_FIRMWARE
    dsp = stage/SENSOR_DATA/'dsp'
    firmware.mkdir(parents=True)
    dsp.mkdir(parents=True)
    for name, expected in sorted(files['modem.img'].items()):
        dest = firmware/name
        subprocess.run(['mcopy', '-i', stock/'modem.img', '::/image/' + name, dest], check=True)
        if not dest.stat().st_size or digest(dest) != expected:
            raise ValueError(f'Extracted SLPI payload failed verification: {name}')
    for name, expected in sorted(files['dsp.img'].items()):
        dest = dsp/name
        # debugfs opens read-only unless explicitly given -w. Quote the output
        # filename for its command parser even when TMPDIR contains spaces.
        command = f'dump /sdsp/{name} "{dest}"'
        subprocess.run(['debugfs', '-R', command, stock/'dsp.img'], check=True, capture_output=True)
        if not dest.stat().st_size or digest(dest) != expected:
            raise ValueError(f'Extracted SDSP payload failed verification: {name}')
    return verify_split_slpi(firmware)


def build(stock, asphalt, output):
    image_hashes, files = verified_inputs(stock)
    output.mkdir(parents=True, exist_ok=True)
    result = output/f'{PACKAGE}_{VERSION}_all.deb'
    with tempfile.TemporaryDirectory(prefix='y700-ssc-firmware-') as temp:
        work = Path(temp)
        stage = work/'package'
        loaded = extract_images(stock, stage, files)
        registry = work/'registry'
        subprocess.run([sys.executable, REPO/'scripts/build-sensor-registry.py', registry,
                        '--asphalt-checkout', asphalt], check=True)
        data = stage/SENSOR_DATA
        shutil.copytree(registry/'etc', data/'etc')
        shutil.copytree(registry/'seed', data/'seed')
        receipt = {'firmware': 'TB320FC_PRC ZUI 17.0.350 CN', 'stock_images': image_hashes,
                   'extracted_files': files, 'file_backed_load_segments': loaded,
                   'registry': json.loads((registry/'build-receipt.json').read_text())}
        (data/'provenance.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')

        control = stage/'DEBIAN/control'
        control.parent.mkdir()
        control.write_text(f'''Package: {PACKAGE}
Version: {VERSION}
Architecture: all
Maintainer: Y700 Linux OS contributors <maintainers@example.invalid>
Section: non-free-firmware/kernel
Priority: optional
Description: Private Lenovo TB320FC_PRC CN350 sensor firmware and defaults
 Locally assembled from verified OEM images. Contains no device calibration.
''')
        for path in [stage, *stage.rglob('*')]:
            if path.is_symlink():
                raise ValueError(f'Unexpected symbolic link in private payload: {path}')
            path.chmod(0o755 if path.is_dir() else 0o644)
            os.utime(path, (EPOCH, EPOCH))
        env = dict(os.environ, SOURCE_DATE_EPOCH=str(EPOCH))
        handle, temporary = tempfile.mkstemp(prefix=f'.{result.name}.', dir=output)
        os.close(handle)
        try:
            subprocess.run(['dpkg-deb', '--root-owner-group', '--build', stage, temporary], check=True, env=env)
            os.chmod(temporary, 0o644)
            os.replace(temporary, result)
        finally:
            Path(temporary).unlink(missing_ok=True)
    print(f'{result.name}: {digest(result)}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock', type=Path, help='Locally verified CN350 modem.img and dsp.img')
    parser.add_argument('asphalt', type=Path, help='Clean pinned Asphalt checkout')
    parser.add_argument('output', type=Path, help='Private local output directory')
    args = parser.parse_args()
    build(args.stock.resolve(strict=True), args.asphalt.resolve(strict=True), args.output.resolve())
