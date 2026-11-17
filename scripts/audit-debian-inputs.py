"""Match an installed Debian package database to local archives without changes.

Run with uv on Linux. A complete archive set still needs authenticated
repository provenance; this tool never invents absent signature evidence.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def audit(root, caches):
    installed = subprocess.check_output(
        ['dpkg-query', f'--admindir={root}/var/lib/dpkg', '-W',
         '-f=${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n'], text=True)
    wanted = []
    for line in installed.splitlines():
        name, version, architecture, status = line.split('\t')
        if status == 'installed':
            wanted.append((name, version, architecture))
    archives = {}
    conflicts = []
    for cache in caches:
        for path in sorted(cache.glob('*.deb')):
            fields = subprocess.check_output(
                ['dpkg-deb', '-f', str(path), 'Package', 'Version', 'Architecture'], text=True)
            fields = dict(line.split(': ', 1) for line in fields.splitlines())
            key = tuple(fields[field] for field in ('Package', 'Version', 'Architecture'))
            with path.open('rb') as archive:
                sha256 = hashlib.file_digest(archive, 'sha256').hexdigest()
            value = dict(package=key[0], version=key[1], architecture=key[2],
                         filename=path.name, size=path.stat().st_size, sha256=sha256)
            if key in archives and archives[key]['sha256'] != sha256:
                conflicts.append(dict(package=key[0], version=key[1], architecture=key[2]))
            else:
                archives[key] = value
    matched = [archives[key] for key in sorted(wanted) if key in archives]
    missing = [dict(package=key[0], version=key[1], architecture=key[2])
               for key in sorted(wanted) if key not in archives]
    return dict(format=1, installed_count=len(wanted), matched_count=len(matched),
                archive_set_complete=not missing and not conflicts,
                repository_signature_chain_revalidated=False,
                scope='archive coverage only, not source authenticity or rootfs content parity',
                missing=missing, conflicting=conflicts, packages=matched)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--cache', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.root, args.cache)
    with args.output.open('x', encoding='utf-8', newline='\n') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'packages'}, indent=2))
    raise SystemExit(0 if result['archive_set_complete'] else 2)
