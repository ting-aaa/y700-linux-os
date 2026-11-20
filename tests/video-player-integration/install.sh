#!/bin/bash
# Keep all player-specific files under /usr/local and the original Debian paths under dpkg.
set -euo pipefail
export LC_ALL=C
mode=${1:---check}
case $mode in --check|--install|--verify) ;; *) echo 'Usage: install.sh [--check|--install|--verify]' >&2; exit 2 ;; esac
cd "$(dirname "$0")"
sha256sum --quiet --strict -c SHA256SUMS
desktop=usr/local/share/applications/org.xfce.Parole.desktop
plugin=usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so
files=("$plugin" usr/local/share/doc/y700-parole/{COPYING,debian-copyright,NOTICE} usr/local/bin/y700-parole "$desktop")
for file in "${files[@]}"; do
    if [[ -L /$file || -e /$file ]]; then
        [[ -f /$file && ! -L /$file ]] && cmp -s "payload/$file" "/$file" ||
            { echo "Local file conflict: /$file" >&2; exit 1; }
    elif [[ $mode == --verify ]]; then
        echo "Missing integrated player file: /$file" >&2
        exit 1
    fi
done
check_stock() {
    sha256sum --quiet --check - <<'HASH'
844986bb49db504a7e5611af2496b4f80f85af74fdc6ce068f0d259fa9c1c93f  /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so
04583897047fbd73626013b99297721f366f5f3b2ecd87dc657cf58eb6c56f04  /usr/share/applications/org.xfce.Parole.desktop
HASH
}
work=$(mktemp -d)
staging=
trap 'rm -r -- "$work"; if [[ -n $staging ]]; then rm -f -- "$staging"; fi' EXIT
tar -xzf debian-player.tar.gz -C "$work"
bash "$work/y700-video-player/install.sh" --check
if [[ $mode == --check ]]; then exit 0; fi
if [[ $mode == --install ]]; then
    [[ $EUID == 0 ]]
    bash "$work/y700-video-player/install.sh" --install
    check_stock
    for file in "${files[@]}"; do
        if [[ -e /$file ]]; then continue; fi
        install -d -m755 "/$(dirname "$file")"
        staging=$(mktemp "/$(dirname "$file")/.y700-parole.XXXXXXXX")
        install -m"$(stat -c %a "payload/$file")" "payload/$file" "$staging"
        ln -- "$staging" "/$file" || cmp -s "$staging" "/$file"
        rm -f -- "$staging"
        staging=
    done
    if ! grep -Eq '^video/mp4=.*org\.xfce\.Parole\.desktop;' /usr/local/share/applications/mimeinfo.cache 2>/dev/null ||
       ! grep -Eq '^video/webm=.*org\.xfce\.Parole\.desktop;' /usr/local/share/applications/mimeinfo.cache 2>/dev/null; then
        update-desktop-database /usr/local/share/applications
    fi
fi
check_stock
test -x /usr/local/bin/y700-parole
for type in mp4 webm; do grep -Eq "^video/$type=.*org\.xfce\.Parole\.desktop;" /usr/local/share/applications/mimeinfo.cache; done
echo 'Verified integrated Parole desktop entry, private plugin and original Debian files.'
