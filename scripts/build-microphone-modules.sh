#!/usr/bin/env bash
# Build the optional TB320FC capture modules in an overlay of the prepared PRC tree.
set -euo pipefail
export LC_ALL=C
if [[ ${1:-} != --inside ]]; then
    [[ $# == 3 && $EUID == 0 ]] || { echo 'Usage as root: build-microphone-modules.sh PREPARED_KERNEL DEV12.9_ROOT.ext4 NEW_OUTPUT' >&2; exit 2; }
    exec unshare --mount --propagation private bash "$0" --inside "$@"
fi
shift
src=$(realpath -e "$1")
disk=$(realpath -e "$2")
out=$(realpath -m "$3")
base=$(dirname "$out")
repo=$(cd "$(dirname "$0")/.." && pwd)
jobs=${JOBS:-6}
[[ $jobs =~ ^[1-9][0-9]*$ && -d $base && $out != "$src" && $out != "$src/"* ]]
[[ ! -e $out && ! -L $out ]] || { echo "Output already exists: $out" >&2; exit 2; }
umask 022
scratch=$(mktemp -d /var/tmp/y700-mic-modules.XXXXXXXX)
result=$(mktemp -d "$base/.y700-mic-result.XXXXXXXX")
cleanup() {
    cd /
    if [[ -f $result/build.log ]]; then tail -15 "$result/build.log" >&2; fi
    for point in "$scratch/tree" "$scratch/disk"; do
        if mountpoint -q "$point" && ! umount "$point"; then
            sleep 1
            umount "$point" || { echo "Retained private build scratch at $scratch" >&2; return 1; }
        fi
    done
    rm -r --one-file-system -- "$scratch"
    if [[ -d $result ]]; then rm -r --one-file-system -- "$result"; fi
}
trap cleanup EXIT
mkdir "$scratch"/{tree,upper,work,disk}
mount --bind "$src" "$src"
mount -o remount,bind,ro "$src"
mount -t overlay overlay -o "lowerdir=$src,upperdir=$scratch/upper,workdir=$scratch/work" "$scratch/tree"
mount -o loop,ro,noload "$disk" "$scratch/disk"
cd "$src"
cat > "$result/kernel-inputs.sha256" <<'HASH'
9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  arch/arm64/boot/Image
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83  Module.symvers
bdcb10cbce42c563d2b4f8563779d3be62c8de7dca135470efc21a664d8a0957  vmlinux.o
56c915a4585c9ba956e7f0f5573e4582912d47b3eb1bc217293935230aa28947  System.map
4626edf0d6fc948d3ae91160b0497ce3f394d47bcbefc34f607e87559f015fef  sound/soc/qcom/sc8280xp.c
37ad9373051ca515d2b33e3e38c3506f10dac003a71b8c82fcb7f81f2048a58b  sound/soc/codecs/lpass-tx-macro.c
HASH
sha256sum --strict -c "$result/kernel-inputs.sha256"
root_hash=e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb
echo "$root_hash  $disk" | sha256sum --strict -c -
release=$(cat include/config/kernel.release)
[[ $release == 7.3.4-asphalt-prc ]]
targets=(drivers/base/regmap/regmap-sdw.ko drivers/soundwire/soundwire-qcom.ko
    sound/soc/codecs/snd-soc-{wcd-common,wcd-mbhc,wcd-classh,wcd938x,wcd938x-sdw}.ko
    sound/soc/codecs/snd-soc-lpass-{macro-common,va-macro,rx-macro,tx-macro}.ko
    sound/soc/qcom/snd-soc-sc8280xp.ko)
machine=sound/soc/qcom/snd-soc-sc8280xp.ko
speakers=(snd-soc-cs35l45 snd-soc-cs35l45-i2c)
stage="$result/staged"
moddir="$stage/lib/modules/$release"
original="$scratch/disk/usr/lib/modules/$release"
mkdir -p "$stage/lib/modules" "$result/modules" "$result/closure"
cp -a "$original" "$moddir"
cd "$scratch/tree"
patches=(config/kernel/asphalt-lpass-tx-stereo.patch config/kernel/asphalt-tx3-dma-map.patch)
(cd "$repo" && sha256sum "${patches[@]}") > "$result/patches.sha256"
for p in "${patches[@]}"; do patch --no-backup-if-mismatch --fuzz=0 -p1 < "$repo/$p"; done
unset KBUILD_OUTPUT KCONFIG_CONFIG KBUILD_EXTMOD KBUILD_EXTRA_SYMBOLS KBUILD_MODPOST_WARN KBUILD_MODPOST_NOFINAL MODPROBE_OPTIONS
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-21 00:00:00 UTC'
kbuild=(make -j"$jobs" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-)
scripts/config -m SOUNDWIRE_QCOM -m SND_SOC_WCD938X_SDW -m SND_SOC_LPASS_VA_MACRO \
    -m SND_SOC_LPASS_RX_MACRO -m SND_SOC_LPASS_TX_MACRO
"${kbuild[@]}" olddefconfig > "$result/build.log" 2>&1
printf '%s  .config\n' 830dd1a2aed821ae4cc38b6c37c56630ba69cf7c59b486692a7b9769607a61d6 | sha256sum --strict -c -
cp .config "$result/candidate.config"
diff -U0 --label baseline.config --label candidate.config "$src/.config" .config > "$result/config.delta" || [[ $? == 1 ]]

# Single-target Kbuild reads vmlinux.o and the requested objects. Supply the
# remaining existing modules' exports from the identical PRC build to modpost.
printf '%s\n' "${targets[@]%.ko}" > "$scratch/rebuilt"
awk 'NR==FNR { rebuilt[$1]=1; next } $3!="vmlinux" && !($3 in rebuilt)' "$scratch/rebuilt" "$src/Module.symvers" > "$scratch/retained.symvers"
cat > "$scratch/modpost" <<'POST'
#!/bin/sh
exec scripts/mod/modpost -i "$(dirname "$0")/retained.symvers" "$@"
POST
chmod 755 "$scratch/modpost"
"${kbuild[@]}" "MODPOST=$scratch/modpost" "${targets[@]}" >> "$result/build.log" 2>&1
cmp "$src/include/config/kernel.release" include/config/kernel.release
cmp "$src/arch/arm64/boot/Image" arch/arm64/boot/Image
awk 'NR==FNR { rebuilt[$1]=1; next } $3 in rebuilt' "$scratch/rebuilt" Module.symvers > "$result/new-exports.tsv"
vermagic=$(modinfo -F vermagic "$original/kernel/$machine.zst")
for target in "${targets[@]}"; do
    [[ $(modinfo -F vermagic "$target") == "$vermagic" ]]
    llvm-readelf -h "$target" | grep -q 'Machine:.*AArch64'
    if [[ $target != "$machine" ]]; then
        [[ ! -e "$original/kernel/$target.zst" ]]
        printf '%s\n' "kernel/$target" >> "$moddir/modules.order"
    fi
    install -Dm644 "$target" "$result/modules/$target"
    mkdir -p "$moddir/kernel/$(dirname "$target")"
    zstd --quiet -f -19 "$target" -o "$moddir/kernel/$target.zst"
done
depmod -C /dev/null -e -F "$src/System.map" -b "$stage" "$release" 2> "$result/depmod.log"
if [[ -s $result/depmod.log ]]; then cat "$result/depmod.log" >&2; exit 1; fi
while read -r alias expected; do
    resolved=$(modprobe -C /dev/null -d "$stage" -S "$release" --resolve-alias "$alias")
    [[ $resolved == "$expected" ]]
    printf '%s\t%s\n' "$alias" "$resolved"
done > "$result/aliases.tsv" <<'ALIASES'
of:NsoundTnoneClenovo,y700-sndcard snd_soc_sc8280xp
i2c:cs35l45 snd_soc_cs35l45_i2c
of:NcodecTnoneCqcom,wcd9380-codec snd_soc_wcd938x
of:NcodecTnoneCqcom,wcd9385-codec snd_soc_wcd938x
sdw:m0217p010Dv00c00 snd_soc_wcd938x_sdw
ALIASES
# Every original module payload except the board machine driver must stay byte-identical.
(cd "$original" && find kernel -name '*.ko.zst' ! -path "kernel/$machine.zst" -print0 | sort -z | xargs -0 sha256sum) > "$scratch/original-modules.sha256"
(cd "$moddir" && sha256sum --quiet --strict -c "$scratch/original-modules.sha256")
awk '$3=="vmlinux" {print $2}' "$src/Module.symvers" | sort -u > "$scratch/core-exports"
for name in "${targets[@]}" "${speakers[@]}"; do
    module=${name##*/}; module=${module%.ko}
    modprobe -C /dev/null -d "$stage" -S "$release" --show-depends "$module" > "$scratch/probe"
    mapfile -t paths < <(sed -n '/^insmod /{s/^insmod //; s/ *$//; p;}' "$scratch/probe")
    [[ ${#paths[@]} -gt 0 && ${paths[-1]##*/} == "$module.ko.zst" ]]
    for path in "${paths[@]}"; do
        [[ $path == "$moddir/kernel/"* && -f $path ]]
        printf 'insmod %s\n' "${path#"$stage/"}"
    done > "$result/closure/$module.txt"
    if [[ $name != *.ko ]]; then
        cmp "${paths[-1]}" "$original/kernel/sound/soc/codecs/$module.ko.zst"
        continue
    fi
    {
        cat "$scratch/core-exports"
        for path in "${paths[@]:0:${#paths[@]}-1}"; do
            zstd -qd < "$path" > "$scratch/dependency.ko"
            llvm-nm --defined-only --format=posix "$scratch/dependency.ko" | sed -n 's/^__ksymtab_\([^ ]*\) .*/\1/p'
        done
    } | sort -u > "$scratch/available"
    llvm-nm --undefined-only --format=posix "$name" | awk '$2=="U" { print $1 }' | sort -u > "$scratch/required"
    comm -23 "$scratch/required" "$scratch/available" > "$scratch/unresolved"
    if [[ -s $scratch/unresolved ]]; then echo "Unresolved symbols in $name:" >&2; cat "$scratch/unresolved" >&2; exit 1; fi
    printf '%s\t%s\t%s\n' "$module" "$(wc -l < "$scratch/required")" "${#paths[@]}" >> "$result/module-checks.tsv"
done
(cd "$src" && sha256sum --quiet --strict -c "$result/kernel-inputs.sha256")
(cd "$result" && find modules -name '*.ko' -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$stage" && find lib/modules -type f -print0 | sort -z | xargs -0 sha256sum) > "$result/staged.sha256"
printf 'release=%s\nvermagic=%s\nsealed_root_sha256=%s\nmodversions=disabled\nnew=11\nreplaced=1\nretained_modules=%s\nretained_speaker_drivers=2\nunresolved=0\n' \
    "$release" "$vermagic" "$root_hash" "$(wc -l < "$scratch/original-modules.sha256")" > "$result/verification.txt"
mv -nT -- "$result" "$out"
[[ ! -e $result ]]
cat "$out/verification.txt" "$out/SHA256SUMS"
