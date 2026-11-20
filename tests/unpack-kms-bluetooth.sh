#!/usr/bin/env bash
# Run on Linux with qemu-img and e2fsprogs. The unpacker checks production free space.
set -euo pipefail
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
bundle=$work/bundle
base=$bundle/base
mkdir -p "$base"
cp -- "$repo/scripts/unpack-kms-update.sh" "$bundle/unpack.sh"

cat > "$base/unpack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
base=$(dirname -- "$0")
if [[ $1 == --verify ]]; then
    (cd "$base" && sha256sum --strict -c SHA256SUMS)
    exit
fi
mkdir "$1"
for name in asphalt-prc-u-boot.img linux-boot.fat; do
    cp -- "$base/$name.zst" "$1/$name"
done
if [[ ${FIXTURE_LINK_ROOT:-} == yes ]]; then
    ln -- "$base/root.ext4.zst" "$1/root.ext4"
else
    cp --sparse=always -- "$base/root.ext4.zst" "$1/root.ext4"
fi
cp -- "$base/identity.txt" "$1/identity.txt"
cp -- "$base/RAW-SHA256SUMS" "$1/SHA256SUMS"
EOF

qcam=y700-camera-qcam_0.7.2-1~bpo13+1.y7002_arm64.deb
blueman=blueman_2.4.4-1+y7001_arm64.deb
full_layer_versions=(dev11.1 dev12.1 dev12.2 dev12.4)
versions=(dev8 dev9 dev10 "${full_layer_versions[@]}")
for name in "${versions[@]}"; do
    printf 'Synthetic platform fixture\n' > "$bundle/y700-platform_0.1.0~${name}_all.deb"
done
printf 'Synthetic qcam fixture\n' > "$bundle/$qcam"
printf 'Synthetic Blueman fixture\n' > "$bundle/$blueman"
printf 'Synthetic offline IME fixture\n' > "$bundle/chinese-ime.tar"
printf 'Synthetic Xorg DSI fixture\n' > "$bundle/xorg-dsi.tar"
printf 'Synthetic bootloader fixture\n' > "$base/asphalt-prc-u-boot.img.zst"
printf 'Synthetic ESP fixture\n' > "$base/linux-boot.fat.zst"
printf 'Synthetic identity fixture\n' > "$bundle/identity.txt"
cp -- "$bundle/identity.txt" "$base/identity.txt"
truncate -s 16M "$base/root.ext4.zst"
mkfs.ext4 -q -F "$base/root.ext4.zst"
debugfs -w -R 'mkdir /etc' "$base/root.ext4.zst" 2> "$work/debugfs.log"
debugfs -w -R 'mkdir /etc/y700' "$base/root.ext4.zst" 2>> "$work/debugfs.log"
ln -s base/root.ext4.zst "$bundle/root.ext4"
for name in "${versions[@]}"; do
    (cd "$bundle" && qemu-img create -q -f qcow2 -F raw -b root.ext4 "$name.qcow2")
done
rm -- "$bundle/root.ext4"

manifest() {
    local version=$1
    shift
    (
        cd "$base"
        sha256sum asphalt-prc-u-boot.img.zst linux-boot.fat.zst root.ext4.zst identity.txt |
            sed 's/\.zst$//' > RAW-SHA256SUMS
        sha256sum asphalt-prc-u-boot.img.zst linux-boot.fat.zst root.ext4.zst identity.txt RAW-SHA256SUMS > SHA256SUMS
    )
    cp -- "$base/RAW-SHA256SUMS" "$bundle/RAW-SHA256SUMS"
    (cd "$bundle" && sha256sum base/SHA256SUMS base/unpack.sh "$version.qcow2" identity.txt RAW-SHA256SUMS \
        "y700-platform_0.1.0~${version}_all.deb" "$@" > SHA256SUMS)
}

unpack() { bash "$bundle/unpack.sh" "$@"; }
check_rolled_back() {
    [[ ! -e $work/rejected && ! -L $work/rejected ]]
    if compgen -G "$work/.y700-*" >/dev/null; then
        echo 'Extraction left a partial staging directory' >&2
        exit 1
    fi
}
reject() {
    local error=$1
    shift
    if unpack "$@" > "$work/rejected.log" 2>&1; then
        echo 'Unexpected successful extraction' >&2
        exit 1
    fi
    [[ -z $error ]] || grep -Fq -- "$error" "$work/rejected.log"
    check_rolled_back
}

for version in "${full_layer_versions[@]}"; do
    manifest "$version" "$qcam" "$blueman" chinese-ime.tar xorg-dsi.tar
    unpack --verify >/dev/null
    manifest "$version" "$qcam" "$blueman" chinese-ime.tar
    reject 'Unsupported update manifest' --verify
done
manifest dev10 "$qcam" "$blueman" chinese-ime.tar xorg-dsi.tar
unpack --verify >/dev/null
printf 'Corrupt panel archive\n' >> "$bundle/xorg-dsi.tar"
reject 'xorg-dsi.tar: FAILED' --verify
manifest dev10 "$qcam" "$blueman" xorg-dsi.tar
reject 'Unsupported update manifest' --verify
manifest dev9 "$qcam" "$blueman" chinese-ime.tar xorg-dsi.tar
reject 'Unsupported update manifest' --verify
manifest dev10 "$qcam" "$blueman" chinese-ime.tar
unpack --verify >/dev/null
manifest dev10 "$qcam" "$blueman"
reject 'Unsupported update manifest' --verify
manifest dev8
unpack --verify >/dev/null
manifest dev9
unpack --verify >/dev/null
manifest dev9 "$qcam"
unpack --verify >/dev/null
manifest dev9 "$qcam" "$blueman"
unpack --verify >/dev/null
manifest dev9 "$qcam" "$blueman" chinese-ime.tar
unpack --verify >/dev/null
printf 'Corrupted offline archive\n' >> "$bundle/chinese-ime.tar"
reject 'chinese-ime.tar: FAILED' --verify
manifest dev9 "$qcam" chinese-ime.tar
reject 'Unsupported update manifest' --verify
manifest dev9 "$qcam" chinese-ime.tar "$blueman"
reject 'Unsupported update manifest' --verify
manifest dev9 "$blueman"
reject 'Unsupported update manifest' --verify
manifest dev9 "$blueman" "$qcam"
reject 'Unsupported update manifest' --verify
manifest dev8 "$qcam" "$blueman"
reject 'Unsupported update manifest' --verify
manifest dev9 "$qcam" "$blueman"
printf 'Corrupted independent archive\n' >> "$bundle/$blueman"
reject 'FAILED' --verify
manifest dev9 "$qcam"

address=/etc/y700/bluetooth-address
seed=$work/seed
expected=$work/expected
printf '%s' '02:ab:00:00:12:34' > "$seed"
printf '%s\n' '02:AB:00:00:12:34' > "$expected"
chmod 400 "$seed"
unpack "$work/generic" > "$work/generic.log"
cmp -- "$base/root.ext4.zst" "$work/generic/root.ext4"
cmp -- "$bundle/RAW-SHA256SUMS" "$work/generic/SHA256SUMS"
[[ ! -e $work/generic/UNPERSONALIZED-SHA256SUMS ]]
unpack --bluetooth-address "$seed" "$work/personal" > "$work/positive.log"
(cd "$work/personal" && sha256sum --strict -c SHA256SUMS && e2fsck -fn root.ext4) > "$work/check.log" 2>&1
cmp -- "$bundle/RAW-SHA256SUMS" "$work/personal/UNPERSONALIZED-SHA256SUMS"
cmp -- "$bundle/RAW-SHA256SUMS" "$work/generic/SHA256SUMS"
for name in asphalt-prc-u-boot.img linux-boot.fat identity.txt; do
    cmp -- "$work/generic/$name" "$work/personal/$name"
done
debugfs -R "stat $address" "$work/personal/root.ext4" > "$work/stat" 2>> "$work/debugfs.log"
grep -Eq 'Type: regular[[:blank:]]+Mode:[[:blank:]]+0600' "$work/stat"
grep -Eq '^User:[[:blank:]]+0[[:blank:]]+Group:[[:blank:]]+0[[:blank:]]' "$work/stat"
debugfs -R "dump $address $work/content" "$work/personal/root.ext4" 2>> "$work/debugfs.log"
cmp -s -- "$work/content" "$expected"
! cmp -s -- "$work/generic/root.ext4" "$work/personal/root.ext4"
reject 'Choose a new destination' --bluetooth-address "$seed" "$work/personal"

cp -- "$bundle/SHA256SUMS" "$work/delta-manifest"
touch "$bundle/prepare-bluetooth-identity.py" "$bundle/README.md"
(cd "$bundle" && sha256sum base/SHA256SUMS base/unpack.sh unpack.sh prepare-bluetooth-identity.py README.md > SHA256SUMS)
unpack --verify >/dev/null
unpack "$work/full" > "$work/full.log"
cmp "$work/full/root.ext4" "$work/generic/root.ext4"
unpack --bluetooth-address "$seed" "$work/full-personal" > "$work/full-personal.log"
(cd "$work/full-personal" && sha256sum --strict -c SHA256SUMS) >/dev/null
debugfs -R "dump $address $work/full-content" "$work/full-personal/root.ext4" 2>> "$work/debugfs.log"
cmp -- "$work/full-content" "$expected"
printf 'Changed helper\n' >> "$bundle/prepare-bluetooth-identity.py"
reject 'prepare-bluetooth-identity.py: FAILED' --verify
cp -- "$work/delta-manifest" "$bundle/SHA256SUMS"

chmod 644 "$seed"
reject 'private, caller-owned regular file' --bluetooth-address "$seed" "$work/rejected"
chmod 600 "$seed"
ln -s seed "$work/symlink"
reject 'private, caller-owned regular file' --bluetooth-address "$work/symlink" "$work/rejected"
ln -- "$seed" "$work/hardlink"
reject 'private, caller-owned regular file' --bluetooth-address "$seed" "$work/rejected"
rm -- "$work/hardlink"
printf '%s\n' '02:00:00:00:00:00' > "$seed"
reject 'is a placeholder' --bluetooth-address "$seed" "$work/rejected"
printf '%s\n' '01:00:00:00:12:34' > "$seed"
reject 'is not a unicast address' --bluetooth-address "$seed" "$work/rejected"
printf '%s\r\n' '02:ab:00:00:12:34' > "$seed"
reject 'Expected exactly one' --bluetooth-address "$seed" "$work/rejected"
printf '%s\0' '02:ab:00:00:12:34' > "$seed"
reject 'Expected exactly one' --bluetooth-address "$seed" "$work/rejected"
printf '%s\n\n' '02:ab:00:00:12:34' > "$seed"
reject 'Expected exactly one' --bluetooth-address "$seed" "$work/rejected"
cp -- "$expected" "$seed"
FIXTURE_LINK_ROOT=yes reject '' --bluetooth-address "$seed" "$work/rejected"
cmp -- "$base/root.ext4.zst" "$work/generic/root.ext4"

export FIXTURE_REAL_DEBUGFS=$(command -v debugfs)
mkdir "$work/bin"
cat > "$work/bin/debugfs" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == -w && $3 == 'write '* && ${FIXTURE_DEBUGFS_ERROR:-} == write ]]; then
    printf 'debugfs 1.47.2 (1-Jan-2025)\nwrite: simulated command error with status zero\n' >&2
    exit 0
fi
if [[ $1 == -w && $3 == 'set_inode_field '*' mode 0100600' && ${FIXTURE_DEBUGFS_ERROR:-} == mode ]]; then
    set -- "$1" "$2" "${3%0100600}0100644" "$4"
fi
if [[ $1 == -w && $3 == 'write '* && ${FIXTURE_DEBUGFS_ERROR:-} == interrupted ]]; then
    touch "$FIXTURE_SIGNAL_READY"
    sleep 1
    exit 1
fi
exec "$FIXTURE_REAL_DEBUGFS" "$@"
EOF
chmod +x "$work/bin/debugfs"
PATH="$work/bin:$PATH" FIXTURE_DEBUGFS_ERROR=write \
    reject 'Bluetooth address write failed' --bluetooth-address "$seed" "$work/rejected"
PATH="$work/bin:$PATH" FIXTURE_DEBUGFS_ERROR=mode \
    reject 'metadata readback failed' --bluetooth-address "$seed" "$work/rejected"
PATH="$work/bin:$PATH" FIXTURE_DEBUGFS_ERROR=interrupted FIXTURE_SIGNAL_READY="$work/ready" \
    bash "$bundle/unpack.sh" --bluetooth-address "$seed" "$work/rejected" > "$work/interrupt.log" 2>&1 &
unpacker=$!
for (( attempt = 0; attempt < 80; attempt++ )); do
    if [[ -e $work/ready ]]; then break; fi
    sleep 0.1
done
[[ -e $work/ready ]]
kill -TERM "$unpacker"
status=0
wait "$unpacker" || status=$?
[[ $status == 143 ]]
check_rolled_back

debugfs -w -R "write $expected $address" "$base/root.ext4.zst" > "$work/debugfs-write.log" 2>&1
manifest dev9 "$qcam"
reject 'path already exists' --bluetooth-address "$seed" "$work/rejected"
printf '%s\n' '02:ab:00:00:12:35' > "$seed"
reject 'path already exists' --bluetooth-address "$seed" "$work/rejected"
debugfs -w -R "rm $address" "$base/root.ext4.zst" >> "$work/debugfs-write.log" 2>&1
debugfs -w -R 'rmdir /etc/y700' "$base/root.ext4.zst" >> "$work/debugfs-write.log" 2>&1
debugfs -w -R 'symlink /etc/y700 /lost+found' "$base/root.ext4.zst" >> "$work/debugfs-write.log" 2>&1
manifest dev9 "$qcam"
reject 'Unexpected directory metadata' --bluetooth-address "$seed" "$work/rejected"
unpack --verify >/dev/null
echo 'Personalized ext4, rollback, and all supported portable manifest layouts passed'
