"""Compare unchanged board packages and local runtime files in two mounted roots."""
import hashlib
import os
from pathlib import Path
import stat
import sys


def entry(path):
    meta = path.lstat()
    value = None
    if stat.S_ISREG(meta.st_mode):
        with path.open('rb') as content:
            value = hashlib.file_digest(content, 'sha256').digest()
    elif stat.S_ISLNK(meta.st_mode):
        value = os.readlink(path)
    return meta.st_mode, meta.st_uid, meta.st_gid, value


def paths_under(root, relative):
    directory = root / relative
    return {path.relative_to(root) for path in directory.rglob('*')}


old, new = map(Path, sys.argv[1:])
receipts = Path('var/lib/y700/build')
old_packages = (old / receipts / 'packages.tsv').read_text().splitlines()
new_packages = set((new / receipts / 'packages.tsv').read_text().splitlines())
inherited = set()
count = 0
for row in old_packages:
    name, version, arch = row.split('\t')
    if row not in new_packages or ('y700' not in version and not name.startswith('y700-')):
        continue
    count += 1
    # Multi-Arch: same packages use the architecture-qualified database name.
    for filename in (name + '.list', name + ':' + arch + '.list'):
        listing = old / 'var/lib/dpkg/info' / filename
        if listing.is_file():
            inherited.update(Path(item.lstrip('/')) for item in listing.read_text().splitlines())
            break
    else:
        raise SystemExit(f'Missing dpkg file list for {name}')

for prefix in ('opt', 'usr/local'):
    before = paths_under(old, prefix)
    after = paths_under(new, prefix)
    if before != after:
        raise SystemExit(f'Local runtime path set changed below {prefix}')
    inherited.update(before)
# This reviewed replacement lives in /opt and has its own exact application lock.
inherited.remove(Path('opt/y700-camera/bin/qcam'))
files_checked = 0
for path in sorted(inherited):
    left = old / path
    if left.is_dir() and not left.is_symlink():
        continue
    if entry(left) != entry(new / path):
        raise SystemExit(f'Inherited runtime changed: {path}')
    files_checked += 1
locks = list((old / receipts).glob('*.lock.json'))
for lock in locks:
    if entry(lock) != entry(new / receipts / lock.name):
        raise SystemExit(f'Inherited lock changed: {lock.name}')
print(f'INHERITED_CUSTOM packages={count} files_and_links={files_checked} original_locks={len(locks)}')
