#!/bin/bash
# Compare every package path, mode, link target and uncompressed regular file.
set -euo pipefail
export LC_ALL=C
[[ $# == 2 ]] || { echo 'Usage: check-package.sh STOCK_DEB CANDIDATE_DEB' >&2; exit 2; }
stock=$(realpath -e "$1")
candidate=$(realpath -e "$2")
[[ $(sha256sum "$stock" | cut -d' ' -f1) == 97a91921a83199c35b847807c323e647483bef56353262cc39e52531bda61aa1 ]]
[[ $(dpkg-deb -f "$candidate" Package) == network-manager ]]
[[ $(dpkg-deb -f "$candidate" Architecture) == arm64 ]]
[[ $(dpkg-deb -f "$candidate" Version) == 1.52.1-1+0y7001 ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
daemon=usr/sbin/NetworkManager
wifi=usr/lib/aarch64-linux-gnu/NetworkManager/1.52.1/libnm-device-plugin-wifi.so
for which in stock candidate; do
    deb=${!which}
    dpkg-deb --fsys-tarfile "$deb" | tar --list --verbose --numeric-owner --file=- \
        | awk '$2 != "0/0" { exit 1 }'
    dpkg-deb --raw-extract "$deb" "$work/$which"
    (
        cd "$work/$which"
        md5sum --strict --status -c DEBIAN/md5sums
        find . -printf '%p\t%y\t%m\t%l\n' | sort >"../$which.paths"
        find . -type f ! -path "./$daemon" ! -path "./$wifi" \
            ! -path './DEBIAN/control' ! -path './DEBIAN/md5sums' \
            ! -path './usr/share/doc/network-manager/changelog.Debian.gz' \
            -print0 | sort -z | xargs -0 sha256sum >"../$which.bytes"
        sed -E '/^(Version|Installed-Size):/d' DEBIAN/control >"../$which.control"
        for f in "$daemon" "$wifi"; do
            id=$(basename "$f")
            readelf -dW "$f" | awk '/\(NEEDED\)/{print $NF}' | sort >"../$which.$id.needed"
            nm -D --defined-only --format=posix "$f" | cut -d' ' -f1 | sort -u >"../$which.$id.symbols"
        done
    )
done
for check in paths bytes control; do diff -u "$work/stock.$check" "$work/candidate.$check"; done
for f in "$daemon" "$wifi"; do
    id=$(basename "$f")
    diff -u "$work/stock.$id.needed" "$work/candidate.$id.needed"
    comm -23 "$work/stock.$id.symbols" "$work/candidate.$id.symbols" >"$work/removed"
    if [[ -s $work/removed ]]; then cat "$work/removed"; exit 1; fi
    cmp -s "$work/stock/$f" "$work/candidate/$f" && exit 1
    sha256sum "$work/candidate/$f" | awk -v name="$f" '{print $1, name}'
done
printf 'PASS package structure, original DSO dependencies and exported ABI, maintainer scripts, conffiles and %s other files\n' "$(wc -l <"$work/stock.bytes")"
