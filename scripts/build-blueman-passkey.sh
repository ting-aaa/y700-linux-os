#!/usr/bin/env bash
# Apply the local passkey fix to the authenticated Trixie ARM64 archive.
set -euo pipefail
if (( $# < 2 || $# > 3 )) || [[ ! ${3:-y7002} =~ ^y700[12]$ ]]; then
    echo 'Usage: build-blueman-passkey.sh BLUEMAN_2.4.4-1_ARM64.deb OUTPUT_DIR [y7001|y7002]' >&2
    exit 2
fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
input=$(realpath -e "$1")
output=$(realpath -e "$2")
test -d "$output"
base_version=2.4.4-1
revision=${3:-y7002}
version=$base_version+$revision
archive=$output/blueman_${version}_arm64.deb
digest=$("${UV_BIN:-uv}" run --offline --no-project --python "${BUILD_PYTHON:-/usr/bin/python3}" python - \
    "$repo/config/debian-base.lock.json" "$base_version" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    lock = json.load(source)
assert lock["repository_signature_chain_revalidated"]
matches = [entry["sha256"] for entry in lock["packages"]
           if (entry["package"], entry["version"], entry["architecture"]) == ("blueman", sys.argv[2], "arm64")]
if len(matches) != 1:
    raise SystemExit("Expected exactly one authenticated ARM64 Blueman archive")
print(matches[0])
PY
)
[[ $digest =~ ^[a-f0-9]{64}$ ]]
printf '%s  %s\n' "$digest" "$input" | sha256sum -c -
test "$(dpkg-deb -f "$input" Package)" = blueman
test "$(dpkg-deb -f "$input" Architecture)" = arm64
test "$(dpkg-deb -f "$input" Version)" = "$base_version"

work=$(mktemp -d /tmp/y700-blueman-package.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-blueman-package\.[a-zA-Z0-9]{8}$ ]]
trap 'rm -r --one-file-system -- "$work"' EXIT
root=$work/pkg
dpkg-deb -R "$input" "$root"
patch --batch --forward --fuzz=0 -p1 -d "$root" < "$repo/packaging/blueman/display-passkey-completion.patch"
if [[ $revision == y7002 ]]; then
    for change in agent-entry display-passkey-lifetime; do
        patch --batch --forward --fuzz=0 -p1 -d "$root" < "$repo/packaging/blueman/$change.patch"
    done
fi
sed -i "s/^Version: $base_version\$/Version: $version/" "$root/DEBIAN/control"
(
    cd "$root"
    target=usr/lib/python3/dist-packages/blueman/main/applet/BluezAgent.py
    test "$(grep -Fc "  $target" DEBIAN/md5sums)" = 1
    digest=$(md5sum "$target" | cut -d ' ' -f 1)
    sed -i "\%  $target\$%s/^[[:xdigit:]]\{32\}/$digest/" DEBIAN/md5sums
    md5sum --quiet -c DEBIAN/md5sums
)
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(date -u -d 2026-11-19T00:00:00Z +%s)
dpkg-deb --root-owner-group -Zxz -z9 --build "$root" "$work/blueman.deb"
test "$(dpkg-deb -f "$work/blueman.deb" Version)" = "$version"
if [[ -e $archive ]]; then
    cmp -- "$work/blueman.deb" "$archive"
else
    install -m644 "$work/blueman.deb" "$archive"
fi
sha256sum "$archive"
