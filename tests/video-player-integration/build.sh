#!/bin/bash
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: build.sh DEBIAN_PLAYER.tar.gz PLUGIN.so DEBIAN_SOURCE_DIR NEW.tar.gz' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
src=$(realpath -e "$3")
out=$(realpath -m "$4")
test ! -e "$out"
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
archive=$(mktemp "$(dirname "$out")/.y700-parole.XXXXXXXX")
trap 'rm -r -- "$work"; rm -f -- "$archive"' EXIT
umask 022
top=$work/y700-parole-iris
payload=$top/payload
docs=$payload/usr/local/share/doc/y700-parole
mkdir -p "$docs" "$top/source" "$payload/usr/local/"{bin,lib/y700-parole/gstreamer-1.0,share/applications}
echo "db0dd4a1dbdeb046bab824683c1e085734c743c17f7f2a64b7aee79282312a66  $1" | sha256sum -c -
echo "7c3e57f206c81fa0af09a3cf34d9836a686527212c7738dc4657d6c315ec9962  $2" | sha256sum -c -
install -m644 "$1" "$top/debian-player.tar.gz"
install -m644 "$2" "$payload/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so"
install -m755 "$here/y700-parole" "$payload/usr/local/bin/y700-parole"
install -m755 "$here/install.sh" "$top/"
install -m644 "$here/NOTICE" "$docs/"
patches=$here/../video-vp9
sed -n "/^sha256sum -c - <<'SHA'/,/^SHA$/ { /^[0-9a-f]/p; }" "$patches/build.sh" > "$work/sources.sha256"
[[ $(wc -l < "$work/sources.sha256") == 4 ]]
(cd "$src"; sha256sum -c "$work/sources.sha256")
while read -r digest name; do install -m644 "$src/$name" "$top/source/$name"; done < "$work/sources.sha256"
install -m644 "$patches/"{iris-vp9.patch,iris-color.patch,iris-vp9-startup.h,iris-input-color.h} "$top/source/"
install -m755 "$patches/"{build.sh,build-color.sh} "$top/source/"
tar -xOf "$src/gst-plugins-good1.0_1.26.2.orig.tar.xz" gst-plugins-good-1.26.2/COPYING > "$docs/COPYING"
tar -xOf "$src/gst-plugins-good1.0_1.26.2-1+deb13u2.debian.tar.xz" debian/copyright > "$docs/debian-copyright"

tar -xOzf "$top/debian-player.tar.gz" y700-video-player/packages/parole_4.18.2-1_arm64.deb > "$work/parole.deb"
dpkg-deb -x "$work/parole.deb" "$work/debian"
desktop=org.xfce.Parole.desktop
sed -E 's#^Exec=parole( |$)#Exec=/usr/local/bin/y700-parole\1#' \
    "$work/debian/usr/share/applications/$desktop" > "$payload/usr/local/share/applications/$desktop"
grep -Fxq 'Exec=/usr/local/bin/y700-parole %F' "$payload/usr/local/share/applications/$desktop"
(cd "$top"; find payload source -type f -print; printf '%s\n' debian-player.tar.gz install.sh) |
    LC_ALL=C sort | (cd "$top"; xargs sha256sum) > "$top/SHA256SUMS"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$work" -cf - y700-parole-iris |
    gzip -n -1 > "$archive"
chmod 644 "$archive"
ln "$archive" "$out"
sha256sum "$out"
