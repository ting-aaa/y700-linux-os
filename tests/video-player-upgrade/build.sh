#!/bin/bash
# Build a deterministic self-contained player update from the locked component archives.
set -euo pipefail
umask 022
[[ $# == 4 ]] || {
    echo 'Usage: build.sh DEV12.8_COMBINED.tar.gz PAROLE_TOUCH_DIRECTORY NEW_IRIS.so NEW.tar.gz' >&2
    exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
old=$(realpath -e "$1")
parole=$(realpath -e "$2")
elf=$(realpath -e "$3")
out=$(realpath -m "$4")
[[ ! -e $out && ! -L $out ]]
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf '%s  %s\n' 0abe5888335940419fe49d7ca2e03ca17a5f767aeb6b10d2c01de5b34081e64f "$old" | sha256sum --strict -c -
(cd "$repo/tests/video-vp9"; sha256sum --strict -c "$here/seek-source.sha256")
top=$work/y700-player-update
mkdir -p "$top"/{candidate,stock,source/parole}
install -m755 "$here/install.sh" "$here/repack.sh" "$top"
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
install -m644 "$repo/tests/video-vp9/iris-seek.patch" "$top/source/gstreamer/"
install -m755 "$repo/tests/video-vp9/build-seek.sh" "$top/source/gstreamer/"
install -m644 "$repo/tests/video-player-integration/NOTICE" "$top/source/gstreamer/"
(cd "$top"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$work/SHA256SUMS"
install -m644 "$work/SHA256SUMS" "$top"
bash "$top/repack.sh" "$out"
