#!/bin/bash
# Copy the lock candidates and private session scripts into a new test directory.
set -euo pipefail
if (( $# != 2 && $# != 4 )) || [[ $# == 4 && $3 != --rotation-package ]]; then
    echo 'Usage: stage.sh ARCHIVE_DIRECTORY STAGE_DIRECTORY [--rotation-package PLATFORM.deb]' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
archives=$(realpath -e "$1")
if (( $# == 4 )); then
    platform=$(realpath -e "$4")
fi
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
if (( $# == 4 )); then
    [[ $(dpkg-deb -f "$platform" Package) == y700-platform && $(dpkg-deb -f "$platform" Architecture) == all ]]
    echo "ROTATION_PACKAGE version=$(dpkg-deb -f "$platform" Version) sha256=$(sha256sum "$platform" | cut -d' ' -f1)"
    platform_root=$(mktemp -d)
    trap 'rm -rf -- "$platform_root"' EXIT
    dpkg-deb -x "$platform" "$platform_root"
    mkdir rotation
    cp "$platform_root/usr/lib/y700/"{y700-auto-rotate.py,rotation_session.py} rotation/
    cp "$platform_root/usr/share/glib-2.0/schemas/org.y700.tablet.gschema.xml" rotation/
    glib-compile-schemas --strict rotation
    cp "$here/../rotation-session.py" rotation/providers.py
    cp "$here/rotation.py" rotation/
    touch retry-in-place
    sha256sum retry-in-place rotation/* >>SHA256SUMS
fi
