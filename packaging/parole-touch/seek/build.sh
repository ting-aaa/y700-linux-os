#!/bin/bash
# Rebuild Debian's arm64 Parole with the HiDPI toolbar and single-seek scrubbing.
set -euo pipefail
umask 022
[[ $# == 2 && $(dpkg --print-architecture) == arm64 ]] || {
    echo 'Usage on Debian trixie arm64: build.sh SOURCE_DIRECTORY OUTPUT_DIRECTORY' >&2
    exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
source_dir=$(realpath -e "$1")
mkdir -p "$2"
out=$(realpath -e "$2")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
(cd "$source_dir"; sha256sum --strict -c "$here/../sources.sha256")
dpkg-source --no-check -x "$source_dir/parole_4.18.2-1.dsc" "$work/parole-4.18.2"
cd "$work/parole-4.18.2"
patch --fuzz=0 -p1 < "$here/../transport.patch"
patch --fuzz=0 -p1 < "$here/scrub.patch"
{ cat "$here/changelog"; echo; cat "$here/../changelog"; echo; cat debian/changelog; } > "$work/changelog"
mv "$work/changelog" debian/changelog
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(date -u -d "$(dpkg-parsechangelog -S Date)" +%s)
dpkg-buildpackage -B -us -uc --jobs-try="${JOBS:-4}"
name=parole_4.18.2-1+y7002_arm64.deb
[[ $(dpkg-deb -f "$work/$name" Package) == parole ]]
[[ $(dpkg-deb -f "$work/$name" Version) == 4.18.2-1+y7002 ]]
[[ $(dpkg-deb -f "$work/$name" Architecture) == arm64 ]]
file=$(mktemp "$out/.parole.XXXXXXXX")
trap 'rm -rf -- "$work"; rm -f -- "$file"' EXIT
install -m644 "$work/$name" "$file"
ln "$file" "$out/$name" || cmp "$file" "$out/$name"
(cd "$out"; sha256sum "$name")
