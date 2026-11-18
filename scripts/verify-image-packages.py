"""Compare the ARM64 package database of an integrated build root to the input locks."""
import json
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
wanted = set()
for name in ('debian-base.lock.json', 'desktop-repair-auth.lock.json'):
    packages = json.loads((repo / 'config' / name).read_text())['packages']
    wanted.update((p['package'], p['version'], p['architecture']) for p in packages)
control = (repo / 'packaging/control').read_text().splitlines()
version = next(line.split()[1] for line in control if line.startswith('Version: '))
wanted.add(('y700-platform', version, 'all'))
output = subprocess.check_output(['dpkg-query', f'--admindir={Path(sys.argv[1])}/var/lib/dpkg',
                                  '-W', '-f=${Package}\\t${Version}\\t${Architecture}\\t${db:Status-Status}\\n'], text=True)
actual = {tuple(row.split('\t')[:3]) for row in output.splitlines() if row.endswith('\tinstalled')}
if wanted != actual:
    raise SystemExit(f'Package mismatch: missing={sorted(wanted-actual)} extra={sorted(actual-wanted)}')
print(f'Verified {len(actual)} installed packages.')
