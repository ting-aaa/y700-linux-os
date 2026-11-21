#!/bin/bash
set -euo pipefail
umask 022
if [[ $# != 2 || $(dpkg --print-architecture) != arm64 ]]; then
    echo 'Usage on Debian trixie arm64: build.sh SOURCE_DIRECTORY OUTPUT_DIRECTORY' >&2
    exit 2
fi
recipe=$(cd -- "$(dirname -- "$0")" && pwd -P)
sources=$(realpath -e "$1")
mkdir -p -- "$2"
output=$(realpath -e "$2")
(cd "$sources" && sha256sum --strict -c "$recipe/sources.sha256")
work=$(mktemp -d)
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
dpkg-source --no-check -x "$sources/wpa_2.10-24.dsc" wpa
cd wpa
patch --batch --fuzz=0 -p1 < "$recipe/sae-mismatch.patch"
{ cat "$recipe/changelog"; echo; cat debian/changelog; } > "$work/changelog"
mv "$work/changelog" debian/changelog
dpkg-buildpackage -B -us -uc -Ppkg.wpa.nogui,noudeb --jobs-try="${JOBS:-4}"
package=wpasupplicant_2.10-24+0y7001_arm64.deb
[[ $(dpkg-deb -f "$work/$package" Package) == wpasupplicant ]]
[[ $(dpkg-deb -f "$work/$package" Version) == '2:2.10-24+0y7001' ]]
[[ $(dpkg-deb -f "$work/$package" Architecture) == arm64 ]]
install -m644 "$work/$package" "$output/$package"
(cd "$output" && sha256sum "$package")
