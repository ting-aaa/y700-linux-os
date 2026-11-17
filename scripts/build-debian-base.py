"""Build a fresh ARM64 Debian package base from an authenticated archive lock.

Run with uv as root on a Linux host with mmdebstrap and ARM64 binfmt. Only
new repository/root directories are accepted. No device or firmware access.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def build(lock, caches, repository, root):
    if os.geteuid() != 0:
        raise ValueError('mmdebstrap root mode requires Linux root on the build host')
    if (not lock['repository_signature_chain_revalidated'] or lock['unmatched'] or
            not lock['packages'] or len(lock['packages']) != lock['installed_count']):
        raise ValueError('Lock must cover every requested package with authenticated metadata')
    for item in lock['packages']:
        if not re.fullmatch(r'[0-9a-f]{64}', item['sha256']) or item['architecture'] not in ('all', 'arm64'):
            raise ValueError('Invalid hash or unsupported package architecture')
    if root.exists() or repository.exists():
        raise ValueError('Both repository and root output directories must be new')
    available = {}
    for cache in caches:
        for archive in cache.glob('*.deb'):
            available.setdefault(archive.stat().st_size, []).append(archive)
    selected = []
    for item in lock['packages']:
        matching = [path for path in available.get(item['size'], []) if digest(path) == item['sha256']]
        if not matching:
            raise ValueError(f"Missing locked archive: {item['package']}={item['version']}")
        selected.append((item, matching[0]))
    repository.mkdir(parents=False)
    (repository/'pool').mkdir()
    with (repository/'Packages').open('w', encoding='utf-8', newline='\n') as index:
        for item, archive in selected:
            relative = f"pool/{item['sha256']}.deb"
            target = repository/relative
            shutil.copyfile(archive, target)
            target.chmod(0o644)
            if digest(target) != item['sha256']:
                raise ValueError('Copied archive hash mismatch')
            control = subprocess.check_output(['dpkg-deb', '-f', str(target)], text=True)
            index.write(control.rstrip()+'\n')
            index.write(f"Filename: {relative}\nSize: {item['size']}\nSHA256: {item['sha256']}\n\n")
    # This trust flag is confined to a newly generated LOCAL repository whose
    # every archive was checked against the authenticated, versioned lock.
    # No unauthenticated remote repository is added.
    packages = ','.join(f"{item['package']}={item['version']}" for item in lock['packages'])
    subprocess.run(['mmdebstrap', '--architectures=arm64', '--mode=root', '--variant=minbase',
                    '--format=directory', '--aptopt=APT::Install-Recommends "false"',
                    '--aptopt=APT::Install-Suggests "false"', f'--include={packages}',
                    # Empty suite is required for a flat repository without a
                    # Release codename; otherwise mmdebstrap finds no essential
                    # packages matching that codename and cannot seed dpkg.
                    '', str(root), f"deb [trusted=yes] {repository.resolve().as_uri().replace('file:', 'copy:', 1)} ./"], check=True)
    installed = subprocess.check_output(['chroot', str(root), 'dpkg-query', '-W',
                                         '-f=${Package}\t${Version}\t${Architecture}\n'], text=True)
    expected = sorted((item['package'], item['version'], item['architecture']) for item in lock['packages'])
    if sorted(tuple(line.split('\t')) for line in installed.splitlines()) != expected:
        raise ValueError('Built root package set differs from lock')
    # A new installed system uses authenticated normal Debian updates, never a
    # build-host file URI or the temporary local repository trust flag.
    (root/'etc/apt/sources.list').write_text(
        'deb https://deb.debian.org/debian trixie main non-free-firmware\n'
        'deb https://deb.debian.org/debian trixie-updates main non-free-firmware\n'
        'deb https://security.debian.org/debian-security trixie-security main non-free-firmware\n')
    (root/'.y700-disposable-build-root').touch()
    (root/'.y700-base-packages-complete').touch()
    print(f'PASS: fresh ARM64 base with exactly {len(expected)} locked packages; no historical root copied.')
    print('This is a package base, not a bootable or identity-finalized image.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, required=True)
    parser.add_argument('--cache', type=Path, action='append', required=True)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    try:
        build(json.loads(args.lock.read_text()), args.cache, args.repository.resolve(), args.root.resolve())
    except subprocess.CalledProcessError as error:
        raise SystemExit(f'{error.cmd[0]} failed ({error.returncode}); inspect build output above') from None
