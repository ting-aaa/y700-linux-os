#!/bin/bash
set -euo pipefail
umask 077
[[ $# == 4 || $# == 5 ]] || { echo 'Usage: run-tablet.sh PINNED_USB_SSH GST_TOOLS_ARM64_DEB CLIPS_DIR MODE [PARSER_ROOT]' >&2; exit 2; }
access=$(realpath -e "$1")
deb=$(realpath -e "$2")
clips=$(realpath -e "$3")
mode=$4
case $mode in h264|hevc|vp9|h264-mp4|hevc-mp4|vp9-auto|h264-playbin|hevc-playbin|vp9-playbin) ;; *) exit 2 ;; esac
codec=${mode%%-*}
parser=
v4l2_plugin=
if [[ -n ${IRIS_V4L2_PLUGIN:-} ]]; then
    v4l2_plugin=$(realpath -e "$IRIS_V4L2_PLUGIN")
    [[ ${IRIS_V4L2_SHA256:-} =~ ^[a-f0-9]{64}$ ]]
    printf '%s  %s\n' "$IRIS_V4L2_SHA256" "$v4l2_plugin" | sha256sum --strict --status -c -
fi
if [[ $# == 5 ]]; then
    [[ $mode == *-mp4 || $mode == *-playbin ]]
    parser=$(realpath -e "$5")/usr/lib/aarch64-linux-gnu
fi
here=$(cd "$(dirname "$0")" && pwd -P)
printf '%s  %s\n' 7cd6fe07960b9132dc3b4adfee62ebc074e9213acc157995f68e5aab9f760ad7 "$deb" | sha256sum --strict --status -c -
work=$(mktemp -d)
ram=
cleanup() {
    cd /
    rm -r --one-file-system -- "$work"
    if [[ $ram =~ ^/run/y700-iris\.[[:alnum:]]{8}$ ]]; then
        bash "$access" "rm -r --one-file-system -- '$ram'"
    fi
}
trap cleanup EXIT
dpkg-deb -x "$deb" "$work/tools"
cd "$work"
cp tools/usr/bin/gst-{inspect,launch}-1.0 "$here/board.sh" .
chmod 755 gst-{inspect,launch}-1.0
mkdir "$codec"
cp "$clips/$codec/reference.sha256" "$codec/"
if [[ -f $clips/$codec/geometry ]]; then cp "$clips/$codec/geometry" "$codec/"; else echo '384 256' >"$codec/geometry"; fi
if [[ $codec == vp9 ]]; then
    cp "$clips/$codec/clip.webm" "$codec/"
elif [[ $mode == *-mp4 || $mode == *-playbin ]]; then
    cp "$clips/$codec/clip.mp4" "$codec/"
else
    cp "$clips/$codec/"[0-9][0-9][0-9].au "$codec/"
    [[ $(find "$codec" -name '*.au' | wc -l) == 24 && $(wc -l <"$codec/reference.sha256") == 24 ]]
fi
awk 'length($0)!=64 || /[^a-f0-9]/ {bad=1} END {exit (bad || NR<1 || NR>48)}' "$codec/reference.sha256"
extra=()
if [[ -n $parser ]]; then
    mkdir -m755 parser plugin
    cp "$parser/libgstcodecparsers-1.0.so.0" parser/
    cp "$parser/gstreamer-1.0/libgstvideoparsersbad.so" plugin/
    printf '%s\n' '90a80f9727460f3dc65f0dccfc09ad2f438f531c92c2fa1c4b29a2af97721d60  plugin/libgstvideoparsersbad.so' \
        '3ab9169ed29bb864c3aaedbd56e8f9f79f618a9811f8df271a314876a460a3d9  parser/libgstcodecparsers-1.0.so.0' | sha256sum --strict --status -c -
    chmod 644 plugin/* parser/*
    extra=(plugin/libgstvideoparsersbad.so parser/libgstcodecparsers-1.0.so.0)
fi
if [[ -n $v4l2_plugin ]]; then
    mkdir -p -m755 plugin
    install -m644 "$v4l2_plugin" plugin/libgstvideo4linux2.so
    extra+=(plugin/libgstvideo4linux2.so)
fi
sha256sum board.sh gst-{inspect,launch}-1.0 "$codec"/* "${extra[@]}" >SHA256SUMS
ram=$(bash "$access" 'test "$(findmnt -nro FSTYPE -T /run)" = tmpfs && mktemp -d /run/y700-iris.XXXXXXXX')
[[ $ram =~ ^/run/y700-iris\.[[:alnum:]]{8}$ ]]
tar -cf - board.sh gst-{inspect,launch}-1.0 "$codec" "${extra[@]}" SHA256SUMS | bash "$access" "tar -xf - -C '$ram'"
bash "$access" "cd '$ram' && sha256sum --strict --status -c SHA256SUMS && chmod 755 . '$codec' && chmod 644 '$codec/'* && timeout -k 4 70 unshare --mount --net --propagation private bash board.sh '$ram' '$mode'"
