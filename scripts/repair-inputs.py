"""Record or verify Debian repair archives. Run through uv on the build host."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


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
    args = parser.parse_args()
    actual = inventory(args.directory)
    if args.operation == 'record':
        with args.lock.open('x', encoding='utf-8', newline='\n') as output:
            json.dump({'format': 1, 'scope': 'desktop-repair-only-not-full-rootfs',
                       'packages': actual}, output, indent=2)
            output.write('\n')
    elif actual != json.loads(args.lock.read_text())['packages']:
        raise SystemExit('Repair archive set differs from lock (name/version/architecture/size/hash)')
    print(f'{args.operation}: {len(actual)} repair packages')
