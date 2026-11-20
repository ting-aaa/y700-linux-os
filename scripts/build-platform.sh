#!/usr/bin/env bash
# Build on Linux; no root, chroot, network or tablet access required.
set -euo pipefail
umask 022
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
out=$(realpath -m "${1:-$repo/out/packages}")
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
install -Dm644 "$repo/packaging/control" "$stage/DEBIAN/control"
tar -C "$repo/packaging/root" --exclude='__pycache__' --exclude='*.py[co]' -cf - . |
    tar -C "$stage" -xf -
# Do not inherit DrvFS/NTFS's synthetic executable/world-writable modes.
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
install -Dm755 "$repo/src/session/y700-display" "$stage/usr/bin/y700-display"
install -Dm755 "$repo/scripts/speaker-calibration.py" "$stage/usr/libexec/y700-speaker-calibration"
install -Dm755 "$repo/src/sensors/y700-auto-rotate.py" "$stage/usr/lib/y700/y700-auto-rotate.py"
install -Dm644 "$repo/src/sensors/rotation_session.py" "$stage/usr/lib/y700/rotation_session.py"
glib-compile-schemas --strict --dry-run "$stage/usr/share/glib-2.0/schemas"
install -Dm644 "$repo/config/chromium/99-y700-software-rendering" "$stage/etc/chromium.d/99-y700-software-rendering"
find "$stage/usr/libexec" -type f -exec chmod 755 {} +
find "$stage/etc" -type f | sed "s|^$stage||" | LC_ALL=C sort > "$stage/DEBIAN/conffiles"
version=$(sed -n 's/^Version: //p' "$repo/packaging/control")
if [[ -z ${SOURCE_DATE_EPOCH:-} ]]; then
    # A documentation commit must not change the bytes of a locked build.
    read -r locked_version locked_epoch < <(
        "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python - "$repo/config/platform.lock.json" <<'PY'
import json
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text())
package, = lock["packages"]
print(package["version"], lock["source_date_epoch"])
PY
    )
    if [[ $version == "$locked_version" ]]; then
        SOURCE_DATE_EPOCH=$locked_epoch
    else
        SOURCE_DATE_EPOCH=$(git -C "$repo" log -1 --format=%ct)
    fi
fi
export SOURCE_DATE_EPOCH
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]
(( SOURCE_DATE_EPOCH <= $(date -u +%s) )) || { echo 'Build epoch must not be in the future.' >&2; exit 1; }
install -d "$stage/usr/lib/y700"
printf '%s\n' "$SOURCE_DATE_EPOCH" > "$stage/usr/lib/y700/build-epoch"
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
package="y700-platform_${version}_all.deb"
dpkg-deb --root-owner-group --uniform-compression -Zxz -z6 --build "$stage" "$out/$package"
cd "$out"
sha256sum "$package" > SHA256SUMS
