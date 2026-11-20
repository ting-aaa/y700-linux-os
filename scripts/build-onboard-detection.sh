#!/usr/bin/env bash
# Repack the pinned Debian ARM64 archive with the Onboard preference fix.
set -euo pipefail
if (( $# != 2 )); then
    echo 'Usage: build-onboard-detection.sh STOCK_ONBOARD_ARM64.deb OUTPUT_DIRECTORY' >&2
    exit 2
fi
repo=$(cd "$(dirname -- "$0")/.." && pwd -P)
input=$(realpath -e "$1")
out=$(realpath -e "$2")
test -d "$out"
stock=1.4.1-10
version=$stock+y7002
digest=$("${UV_BIN:-uv}" run --offline --no-project --python "${BUILD_PYTHON:-/usr/bin/python3}" python \
    - "$repo/config/debian-base.lock.json" "$stock" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    lock = json.load(f)
if not lock["repository_signature_chain_revalidated"]:
    sys.exit("Expected authenticated Debian base metadata")
row, = [r for r in lock["packages"] if (r["package"], r["architecture"], r["version"])
        == ("onboard", "arm64", sys.argv[2])]
print(row["sha256"])
PY
)
printf '%s  %s\n' "$digest" "$input" | sha256sum --strict -c -
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
root=$work/package
dpkg-deb -R "$input" "$root"
cd "$root"
patch --batch --fuzz=0 -p1 < "$repo/packaging/onboard/live-keyboard-detection.patch"
sed -i "s/^Version: ${stock//./\\.}\$/Version: $version/" DEBIAN/control
sed -i '/^Depends: /s/$/, python3-pyudev/' DEBIAN/control
for module in AutoShow Keyboard UDevTracker; do
    file=usr/lib/python3/dist-packages/Onboard/$module.py
    test "$(grep -Fc "  $file" DEBIAN/md5sums)" = 1
    hash=$(md5sum "$file")
    sed -i "\\%  $file\$%s/^[[:xdigit:]]\{32\}/${hash%% *}/" DEBIAN/md5sums
done
md5sum --quiet -c DEBIAN/md5sums
export SOURCE_DATE_EPOCH=1795132800
find . -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group -Zxz -z9 --build . "$work/onboard.deb"
test "$(dpkg-deb -f "$work/onboard.deb" Version)" = "$version"
archive=$out/onboard_${version}_arm64.deb
if [[ -e $archive ]]; then cmp "$work/onboard.deb" "$archive"; else install -m644 "$work/onboard.deb" "$archive"; fi
sha256sum "$archive"
