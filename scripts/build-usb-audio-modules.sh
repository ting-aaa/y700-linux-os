#!/usr/bin/env bash
# Optional class-compliant digital USB audio for the dev12.13 PRC kernels.
set -euo pipefail
export LC_ALL=C
if [[ ${1:-} != --private ]]; then
    [[ $# -ge 2 && $# -le 3 && $EUID == 0 ]] || { echo 'Usage as root: build-usb-audio-modules.sh PREPARED_KERNEL NEW_OUTPUT [--test-vhci]' >&2; exit 2; }
    exec unshare --mount --propagation private bash "$0" --private "$@"
fi
shift
here=$(cd "$(dirname "$0")" && pwd)
src=$(realpath -e "$1")
out=$(realpath -m "$2")
[[ -d $(dirname "$out") && ! -e $out && ! -L $out && ( $# == 2 || $3 == --test-vhci ) ]]
work=$(mktemp -d /tmp/y700-uac-build.XXXXXXXX)
result=$(mktemp -d "$(dirname "$out")/.y700-uac-result.XXXXXXXX")
cleanup() {
    cd /
    if mountpoint -q "$work/tree"; then umount "$work/tree" || return; fi
    if mountpoint -q "$work"; then umount "$work" || return; fi
    rmdir "$work"
    if [[ -d $result ]]; then rm -r --one-file-system -- "$result"; fi
}
trap cleanup EXIT
mount -t tmpfs -o size=384M,mode=700 tmpfs "$work"
mkdir "$work"/{upper,overlay-work,tree}
mount -t overlay overlay -o "lowerdir=$src,upperdir=$work/upper,workdir=$work/overlay-work" "$work/tree"
cd "$work/tree"
sha256sum --strict --check <<'HASH'
9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  arch/arm64/boot/Image
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83  Module.symvers
bdcb10cbce42c563d2b4f8563779d3be62c8de7dca135470efc21a664d8a0957  vmlinux.o
HASH
unset KBUILD_OUTPUT KCONFIG_CONFIG KBUILD_EXTMOD KBUILD_EXTRA_SYMBOLS KBUILD_MODPOST_WARN KBUILD_MODPOST_NOFINAL
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-22 00:00:00 UTC' SOURCE_DATE_EPOCH=1795305600
build=(make -j4 ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-)
targets=(sound/core/{snd-hwdep,snd-rawmidi}.ko sound/usb/{snd-usbmidi-lib,snd-usb-audio}.ko)
scripts/config -m SND_USB_AUDIO
if [[ $# == 3 ]]; then
    scripts/config -m USBIP_CORE -m USBIP_VHCI_HCD
    targets+=(drivers/usb/usbip/{usbip-core,vhci-hcd}.ko)
fi
"${build[@]}" olddefconfig > "$result/build.log" 2>&1
diff -U0 --label original --label candidate "$src/.config" .config > "$result/config.delta" || [[ $? == 1 ]]
printf '%s\n' "${targets[@]%.ko}" > "$work/targets"
awk 'NR==FNR { rebuilt[$1]=1; next } $3!="vmlinux" && !($3 in rebuilt)' "$work/targets" "$src/Module.symvers" > "$work/retained.symvers"
cat > "$work/modpost" <<'POST'
#!/bin/sh
exec scripts/mod/modpost -i "$(dirname "$0")/retained.symvers" "$@"
POST
chmod +x "$work/modpost"
if ! "${build[@]}" "MODPOST=$work/modpost" "${targets[@]}" >> "$result/build.log" 2>&1; then tail -40 "$result/build.log" >&2; exit 1; fi
release=$(cat include/config/kernel.release)
[[ $release == 7.3.4-asphalt-prc ]]
pkg=y700-usb-audio-modules
root="$work/pkg"
for target in "${targets[@]}"; do
    [[ $(modinfo -F vermagic "$target") == "$release "* ]]
    if [[ $target == drivers/usb/usbip/* ]]; then
        install -Dm644 "$target" "$result/test-only/${target##*/}"
    else
        dst="$root/usr/lib/modules/$release/updates/$pkg/${target##*/}.zst"
        mkdir -p "$(dirname "$dst")"
        zstd -q -19 "$target" -o "$dst"
    fi
done
mkdir "$root/DEBIAN"
install -m755 "$here/../packaging/usb-audio/preinst" "$root/DEBIAN/preinst"
cat > "$root/DEBIAN/control" <<CTRL
Package: $pkg
Version: 7.3.4-1
Architecture: arm64
Maintainer: Y700 Linux OS contributors
Depends: kmod, zstd
Description: USB Audio Class modules for the TB320FC Debian dev12.13 kernel
 Adds the standard ALSA USB Audio and MIDI 1.0 driver and its dependencies
 for kernel release $release.
CTRL
for hook in postinst postrm; do
    printf '#!/bin/sh\nset -e\ncase "$1" in configure|remove|purge) if [ -d /lib/modules/%s ]; then depmod -a %s; fi ;; esac\n' "$release" "$release" > "$root/DEBIAN/$hook"
    chmod 755 "$root/DEBIAN/$hook"
done
doc="$root/usr/share/doc/$pkg"
mkdir -p "$doc"
{
    echo 'These Linux ALSA module sources are distributed under the licenses below.'
    echo 'GNU GPL version 2 is supplied in /usr/share/common-licenses/GPL-2.'
    for source in sound/core/{hwdep,rawmidi}.c sound/usb/{card,clock,endpoint,fcp,format,helper,implicit,media,midi,mixer,mixer_quirks,mixer_scarlett,mixer_scarlett2,mixer_us16x08,mixer_s1810c,pcm,power,proc,quirks,stream,validate}.c; do
        printf '\n--- %s ---\n' "$source"
        sed -n '1,/^#include/{ /^#include/!p; }' "$source"
    done
} > "$doc/copyright"
(cd "$root" && find usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums)

chmod 755 "$root" "$root/DEBIAN"
find "$root" -exec touch --no-dereference -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group -Zxz --build "$root" "$result/${pkg}_7.3.4-1_arm64.deb"
(cd "$result" && sha256sum *.deb > SHA256SUMS)
mv -T "$result" "$out"
