#!/bin/bash
# Rebuild the Y700 X11 tray integration with Debian's native arm64 packaging.
set -euo pipefail
umask 022
export LC_ALL=C.UTF-8
if [[ $# != 2 || $(dpkg --print-architecture) != arm64 ]]; then
  echo "usage (Debian trixie arm64): $0 DEBIAN_SOURCE_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
sources=$(realpath -e "$1")
mkdir -p "$2"
out=$(realpath -e "$2")
name=xfce4-power-manager
version=4.20.0-1+y7001
archive=${name}_${version}_arm64.deb
work=$(mktemp -d)
staged=
trap 'rm -rf -- "$work"; if [[ -n $staged ]]; then rm -f -- "$staged"; fi' EXIT

# These three hashes come from one signed Debian trixie main/source record.
(
  cd "$sources"
  sha256sum --strict -c - <<'SUMS'
8743ac65954e51f5e50b6f54f8df4e62fbd4aec80b16ea49991e64f52aa41eb4  xfce4-power-manager_4.20.0-1.dsc
e34ca83eeea3bb8bd55ae45221ff939d075d30f7c6197e61e3cd867d6f24e3f3  xfce4-power-manager_4.20.0-1.debian.tar.xz
971391cef63352833bdd92df28957392e17e1f2b3d486c0f57294fd204d6ed29  xfce4-power-manager_4.20.0.orig.tar.bz2
SUMS
)
dpkg-source --no-check -x "$sources/${name}_4.20.0-1.dsc" "$work/$name-4.20.0"
cd "$work/$name-4.20.0"
patch --fuzz=0 -p1 < "$repo/packaging/power-manager-touch/tray-activate.patch"
patch --fuzz=0 -p1 < "$repo/packaging/power-manager-touch/stock-data.patch"
{ cat "$repo/packaging/power-manager-touch/changelog"; echo; cat debian/changelog; } > "$work/changelog"
mv "$work/changelog" debian/changelog
SOURCE_DATE_EPOCH=$(date -u -d "$(dpkg-parsechangelog -S Date)" +%s)
export SOURCE_DATE_EPOCH
dpkg-buildpackage -B -us -uc --jobs-try="${JOBS:-4}"

pkg=$work/$archive
[[ $(dpkg-deb -f "$pkg" Package) == "$name" ]]
[[ $(dpkg-deb -f "$pkg" Version) == "$version" ]]
[[ $(dpkg-deb -f "$pkg" Architecture) == arm64 ]]
dpkg-deb -f "$pkg" Depends | tr ',' '\n' | sed 's/^ *//' | grep -Fx 'xfce4-power-manager-data (= 4.20.0-1)'
staged=$(mktemp "$out/.$name.XXXXXXXX")
install -m 0644 "$pkg" "$staged"
mv -nT "$staged" "$out/$archive"
cmp "$pkg" "$out/$archive"
(cd "$out" && sha256sum "$archive")
