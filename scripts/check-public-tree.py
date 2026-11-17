"""Validate the exact Git index without executing imported build/device recipes."""
import ast
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
names = subprocess.check_output(['git','ls-files','-z'], cwd=root).decode().split('\0')
names = [name for name in names if name]
if not names:
    raise SystemExit('No tracked/staged files to inspect. Stage the intended public tree first.')
errors = []
checks = 0
bash = shutil.which('bash') if sys.platform != 'win32' else None
patterns = {
    'private key': r'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----',
    'access token': r'\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b',
    'embedded SSH public key': r'\bssh-(?:ed25519|rsa)\s+AAAA[A-Za-z0-9+/=]{30,}',
    'private Windows home': r'(?i)(?:[A-Z]:[/\\]|/mnt/[a-z]/)Users[/\\][A-Za-z0-9_-]+',
}
for name in names:
    path = root / name
    index_data = subprocess.check_output(['git','show',f':{name}'], cwd=root)
    if path.is_symlink() or not path.is_file():
        errors.append(f'{name}: symlink or non-file'); continue
    if path.read_bytes() != index_data:
        errors.append(f'{name}: working tree differs from staged content')
    if index_data and (len(index_data) > 1024 * 1024 or b'\0' in index_data):
        errors.append(f'{name}: oversized or binary content'); continue
    if any(part in {'.local','.project-memory','.venv','private','backups'} for part in path.relative_to(root).parts):
        errors.append(f'{name}: private directory is tracked')
    try:
        text = index_data.decode('utf-8')
        for label, pattern in patterns.items():
            if re.search(pattern, text): errors.append(f'{name}: {label}')
        if path.suffix == '.py': ast.parse(text, filename=name)
        if path.suffix == '.json': json.loads(text)
        if bash and (path.suffix == '.sh' or text.startswith(('#!/bin/sh','#!/bin/bash','#!/usr/bin/env bash'))):
            result = subprocess.run([bash,'-n',str(path)], capture_output=True, text=True)
            if result.returncode: errors.append(f'{name}: {result.stderr.strip()}')
    except (UnicodeError, SyntaxError, ValueError) as error:
        errors.append(f'{name}: {error}')
    checks += 1
manifest = json.loads((root / 'docs/import-manifest.json').read_text())
import hashlib
for item in manifest['files']:
    # The import manifest describes the original import, not later development.
    # Keep those immutable hashes verifiable without freezing product sources.
    baseline = subprocess.check_output(
        ['git', 'show', f"{manifest['baseline_commit']}:{item['public_path']}"], cwd=root)
    if hashlib.sha256(baseline).hexdigest() != item['public_sha256']:
        errors.append(f"{item['public_path']}: import manifest hash drift")
if errors:
    print('\n'.join(errors)); raise SystemExit(1)
print(f'PASS: {checks} indexed UTF-8 files; Python/JSON valid; original import hashes match; basic publication scan clean.')
print('Shell syntax: ' + ('checked with Bash' if bash else 'not checked here; rerun in Linux/WSL'))
print('This is not a build, hardware test, license audit, or complete secret detector.')
