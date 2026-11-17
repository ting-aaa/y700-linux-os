"""Authenticate historical Debian indexes and match every requested archive.

This verifies signatures and content, not metadata freshness. Historical
snapshots must not be used to assert a system has current security updates.
Run with uv; gpgv and a separately trusted Debian archive keyring are required.
"""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path, PurePosixPath


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def paragraphs(path):
    record = {}
    with path.open(encoding='utf-8') as stream:
        for line in stream:
            if line == '\n':
                if record:
                    yield record
                    record = {}
            elif not line[0].isspace() and ': ' in line:
                key, value = line.rstrip('\n').split(': ', 1)
                record[key] = value
    if record:
        yield record


def verify(audit, lists, keyring):
    if audit['conflicting'] or not audit['installed_count']:
        raise ValueError('Cannot authenticate empty or conflicting archive audit')
    wanted = {(item['package'], item['version'], item['architecture']): item
              for item in audit['packages'] + audit['missing']}
    found = {}
    metadata = []
    with tempfile.TemporaryDirectory() as temp:
        for number, signed in enumerate(sorted(lists.glob('*_InRelease'))):
            release = Path(temp)/f'release-{number}'
            subprocess.run(['gpgv', '--keyring', str(keyring.resolve()), '--output', str(release), str(signed)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            text = release.read_text()
            header = dict(line.split(': ', 1) for line in text.splitlines()
                          if line and not line[0].isspace() and ': ' in line)
            if header.get('Origin') != 'Debian':
                raise ValueError('Only Debian signed repository metadata is supported')
            expected = {}
            section = False
            for line in text.splitlines():
                if not line.startswith(' '):
                    section = line == 'SHA256:'
                elif section:
                    digest, size, name = line.split()
                    expected[name] = (digest, int(size))
            prefix = signed.name.removesuffix('InRelease')
            entry = dict(file=signed.name, sha256=sha256(signed),
                         date=header.get('Date'), valid_until=header.get('Valid-Until'), indexes=[])
            base = ('https://security.debian.org/debian-security/'
                    if header.get('Label') == 'Debian-Security' else 'https://deb.debian.org/debian/')
            for index in sorted(lists.glob(prefix+'*Packages')):
                relative = index.name[len(prefix):].replace('_', '/')
                digest = sha256(index)
                if expected.get(relative) != (digest, index.stat().st_size):
                    raise ValueError(f'Index does not match signed Release: {index.name}')
                entry['indexes'].append(dict(path=relative, sha256=digest, size=index.stat().st_size))
                for item in paragraphs(index):
                    key = tuple(item.get(field) for field in ('Package', 'Version', 'Architecture'))
                    if key not in wanted:
                        continue
                    filename = PurePosixPath(item['Filename'])
                    if filename.is_absolute() or '..' in filename.parts:
                        raise ValueError('Unsafe repository package path')
                    value = dict(package=key[0], version=key[1], architecture=key[2],
                                 size=int(item['Size']), sha256=item['SHA256'],
                                 uri=base+str(filename), repository_path=str(filename))
                    cached = wanted[key]
                    if 'sha256' in cached and (cached['sha256'], cached['size']) != (value['sha256'], value['size']):
                        raise ValueError(f'Archive differs from authenticated index: {key}')
                    if key in found and found[key]['sha256'] != value['sha256']:
                        raise ValueError(f'Conflicting authenticated package: {key}')
                    found[key] = value
            metadata.append(entry)
    missing = [dict(package=key[0], version=key[1], architecture=key[2])
               for key in sorted(wanted.keys()-found.keys())]
    return dict(format=1, scope='authenticated historical package snapshot; freshness not asserted',
                keyring_sha256=sha256(keyring), metadata=metadata,
                installed_count=len(wanted), authenticated_count=len(found),
                repository_signature_chain_revalidated=not missing,
                unmatched=missing, packages=[found[key] for key in sorted(found)])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--lists', type=Path, required=True)
    parser.add_argument('--keyring', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = verify(json.loads(args.audit.read_text()), args.lists, args.keyring)
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ('metadata', 'packages')}, indent=2))
    raise SystemExit(0 if result['repository_signature_chain_revalidated'] else 2)
