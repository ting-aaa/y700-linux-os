#!/bin/bash
# Copy the lock candidates and private session scripts into a new test directory.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
archives=$(realpath -e "$1")
cd "$2"
cp -- "$archives/"*.deb "$archives/../legacy-deps/libdbus-glib-1-2_0.114-1_arm64.deb" \
    "$here/"{namespace.sh,session.sh,exercise.py} ./
uv run --offline --no-project --python /usr/bin/python3 python - "$here/../../config" <<'PY'
import hashlib, json, pathlib, sys
config = pathlib.Path(sys.argv[1])
pins = json.loads((config / "touch-lock.lock.json").read_text())["packages"]
legacy = json.loads((config / "warm-greeter-debian-auth.lock.json").read_text())["packages"]
pins += [row for row in legacy if row["package"] == "libdbus-glib-1-2"]
archives = sorted(pathlib.Path(".").glob("*.deb"))
assert len(archives) == len(pins) == 4
for row in pins:
    archive, = [f for f in archives if f.name.split("_")[0] == row["package"]]
    assert archive.stat().st_size == row["size"] and hashlib.sha256(archive.read_bytes()).hexdigest() == row["sha256"]
PY
sha256sum *.deb namespace.sh session.sh exercise.py >SHA256SUMS
