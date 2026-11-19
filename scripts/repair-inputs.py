"""Record or verify Debian repair archives. Run through uv on the build host."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from camera_layer import load_camera_lock, validate_camera_lock


def inventory(directory):
    result = []
    for path in sorted(Path(directory).glob('*.deb')):
        values = subprocess.check_output(
            ['dpkg-deb', '-f', str(path), 'Package', 'Version', 'Architecture'], text=True)
        fields = dict(line.split(': ', 1) for line in values.splitlines())
        with path.open('rb') as archive:
            digest = hashlib.file_digest(archive, 'sha256').hexdigest()
        result.append(dict(filename=path.name, package=fields['Package'],
                           version=fields['Version'], architecture=fields['Architecture'],
                           size=path.stat().st_size,
                           sha256=digest))
    if not result:
        raise ValueError('No Debian archives found')
    if len({item['package'] for item in result}) != len(result):
        raise ValueError('Multiple versions of a package found')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['record', 'verify'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('lock', type=Path)
    parser.add_argument('--camera-layer', action='store_true', help='Use the camera dependency provenance')
    args = parser.parse_args()
    kind = 'camera-layer' if args.camera_layer else 'repair'
    actual = inventory(args.directory)
    if args.operation == 'record':
        scope = ('optional-camera-runtime-and-debian-dependencies' if args.camera_layer
                 else 'desktop-repair-only-not-full-rootfs')
        record = {'format': 1, 'scope': scope, 'packages': actual}
        if args.camera_layer:
            validate_camera_lock(record)
        with args.lock.open('x', encoding='utf-8', newline='\n') as output:
            json.dump(record, output, indent=2)
            output.write('\n')
    else:
        def content(items):
            return sorted(({key: value for key, value in item.items() if key != 'filename'}
                           for item in items), key=lambda item: item['package'])
        expected = (load_camera_lock(args.lock) if args.camera_layer
                    else json.loads(args.lock.read_text())['packages'])
        if content(actual) != content(expected):
            raise SystemExit(f'{kind.capitalize()} archive set differs from lock (package/version/architecture/size/hash)')
    print(f'{args.operation}: {len(actual)} {kind} packages')
