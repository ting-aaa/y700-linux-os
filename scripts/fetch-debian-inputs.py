"""Fetch exact locked Debian archives; verified cache entries are reused.

Run through uv. Partial downloads are local and never replace a completed
archive. No APT configuration, installed package or device is changed.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


def matches(path, item):
    if not path.is_file() or path.stat().st_size != item['size']:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == item['sha256']


def fetch(item, directory):
    digest = item['sha256']
    if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
        raise ValueError('Invalid archive hash')
    target = directory/f'{digest}.deb'
    if target.exists():
        if not matches(target, item):
            raise ValueError(f"Existing archive differs from lock: {item['package']}")
        return 'cached'
    uri = urllib.parse.urlparse(item['uri'])
    if uri.scheme != 'https' or uri.hostname not in {'deb.debian.org', 'security.debian.org', 'snapshot.debian.org'}:
        raise ValueError('Only declared Debian HTTPS sources are supported')
    handle, name = tempfile.mkstemp(prefix='.partial-', dir=directory)
    temporary = Path(name)
    try:
        with os.fdopen(handle, 'wb') as output, urllib.request.urlopen(item['uri'], timeout=60) as response:
            remaining = item['size']
            while remaining:
                chunk = response.read(min(1024*1024, remaining))
                if not chunk:
                    break
                output.write(chunk)
                remaining -= len(chunk)
            if response.read(1):
                raise ValueError('Download exceeds locked size')
        if not matches(temporary, item):
            raise ValueError(f"Downloaded archive differs from lock: {item['package']}")
        # Atomic no-overwrite publication, including simultaneous fetchers.
        try:
            os.link(temporary, target)
        except FileExistsError:
            if not matches(target, item):
                raise ValueError('Concurrent archive conflict')
        target.chmod(0o644)
        return 'downloaded'
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text())
    if not lock['repository_signature_chain_revalidated'] or lock['unmatched']:
        raise ValueError('An authenticated complete lock is required')
    args.cache.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as workers:
        results = list(workers.map(lambda item: fetch(item, args.cache), lock['packages']))
    print(f"Verified {len(results)} archives ({results.count('cached')} cached, {results.count('downloaded')} downloaded).")
