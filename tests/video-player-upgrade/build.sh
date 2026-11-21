#!/bin/bash
# Build a deterministic self-contained player update from the locked component archives.
set -euo pipefail
umask 022
[[ $# == 5 ]] || {
    echo 'Usage: build.sh DEV12.8_COMBINED.tar.gz PAROLE_TOUCH_DIRECTORY NEW_IRIS.so SEEK.patch NEW.tar.gz' >&2
    exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
old=$(realpath -e "$1")
parole=$(realpath -e "$2")
elf=$(realpath -e "$3")
patch=$(realpath -e "$4")
out=$(realpath -m "$5")
[[ ! -e $out && ! -L $out ]]
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
archive=$(mktemp "$(dirname "$out")/.parole-update.XXXXXXXX")
trap 'rm -rf -- "$work"; rm -f -- "$archive"' EXIT
printf '%s  %s\n' 0abe5888335940419fe49d7ca2e03ca17a5f767aeb6b10d2c01de5b34081e64f "$old" \
    c8e0ea1043a9743defe5a1569137be44e7fb80dee8158ada35fe6d0f3576e876 "$patch" | sha256sum --strict -c -
top=$work/y700-player-update
mkdir -p "$top"/{candidate,stock,source/parole}
install -m755 "$here/install.sh" "$top"
install -m644 "$here/"{README.md,baseline.sha256,payload.sha256} "$top"
install -m644 "$parole/stock/parole_4.18.2-1_arm64.deb" "$top/stock"
install -m644 "$parole/parole_4.18.2-1+y7001_arm64.deb" "$top/candidate"
install -m644 "$elf" "$top/candidate/libgstvideo4linux2.so"
tar -xOzf "$old" y700-parole-iris/payload/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so > "$top/stock/libgstvideo4linux2.so"
(cd "$top"; sha256sum --strict -c payload.sha256)
(cd "$parole/source"; sha256sum --strict -c "$repo/packaging/parole-touch/sources.sha256")
while read -r digest name; do install -m644 "$parole/source/$name" "$top/source/parole/"; done < "$repo/packaging/parole-touch/sources.sha256"
install -m644 "$repo/packaging/parole-touch/"{changelog,sources.sha256,transport.patch} "$top/source/parole/"
install -m755 "$repo/packaging/parole-touch/build.sh" "$top/source/parole/"
tar -xzf "$old" --strip-components=1 -C "$top/source" y700-parole-iris/source
mv "$top/source/source" "$top/source/gstreamer"
install -m644 "$patch" "$top/source/gstreamer/iris-session-seek.patch"
install -m644 "$repo/tests/video-player-integration/NOTICE" "$top/source/gstreamer/"
(cd "$top"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$work/SHA256SUMS"
install -m644 "$work/SHA256SUMS" "$top"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' \
    -C "$work" -cf - y700-player-update | gzip -n > "$archive"
chmod 644 "$archive"
ln "$archive" "$out"
sha256sum "$out"
