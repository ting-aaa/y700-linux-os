"""Reject changed real signed metadata; uses caller-supplied public indexes.

Run through uv on Linux with --audit, --lists and --keyring. No original input
is changed. This integration test is separate from source-only CI.
"""
import argparse
import importlib.util
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).resolve().parents[1]/'scripts/verify-debian-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--audit', type=Path, required=True)
parser.add_argument('--lists', type=Path, required=True)
parser.add_argument('--keyring', type=Path, required=True)
args = parser.parse_args()
audit = json.loads(args.audit.read_text())
with tempfile.TemporaryDirectory() as temp:
    copies = Path(temp)
    for source in [*args.lists.glob('*_InRelease'), *args.lists.glob('*Packages')]:
        shutil.copyfile(source, copies/source.name)
    signed = next(copies.glob('*_InRelease'))
    original = signed.read_bytes()
    assert b'Origin: Debian' in original
    signed.write_bytes(original.replace(b'Origin: Debian', b'Origin: Invalid', 1))
    try:
        metadata.verify(audit, copies, args.keyring)
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError('Invalid signature was accepted')
    signed.write_bytes(original)
    index = next(copies.glob('*Packages'))
    with index.open('ab') as stream:
        stream.write(b'changed\n')
    try:
        metadata.verify(audit, copies, args.keyring)
    except ValueError as error:
        assert 'Index does not match signed Release' in str(error)
    else:
        raise AssertionError('Changed signed index was accepted')
print('PASS: altered Release signature and altered Packages content rejected.')
