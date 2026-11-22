#!/usr/bin/env bash
# Assemble the volatile RAM-overlay initrd carrying our newly compiled modules,
# AudioReach capture topology, ALSA UCM, and 300-second safety return watchdog.
set -euo pipefail
export LC_ALL=C
umask 077

[[ $# == 4 ]] || {
    echo 'Usage: build-hw-trial-initrd.sh BASE_INITRD HW_BUILD_DIR TX3_TPLG NEW_OUT_DIR' >&2
    exit 2
}

base_initrd=$(realpath -e "$1")
hw_build=$(realpath -e "$2")
tx3_tplg=$(realpath -e "$3")
out=$(realpath -m "$4")
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ ! -e $out && ! -L $out ]]

(cd "$hw_build" && sha256sum --strict --quiet -c SHA256SUMS)
[[ $(sha256sum "$tx3_tplg" | awk '{print $1}') == aa6d0c1a904bafa20915528cae810ee08560d262f174c52465c386629e1b6422 ]]

work=$(mktemp -d "${TMPDIR:-/var/tmp}/.y700-hw-initrd.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

stage=$work/newc
mkdir -p "$stage/hw-overlay/modules" "$stage/hw-overlay/firmware" "$stage/hw-overlay/ucm2" "$work/bundle"

install -m755 "$repo/src/boot/hw-overlay-init" "$stage/y700-hw-overlay-init"

# Compress all 15 built modules as .ko.zst preserving kernel-relative paths
while IFS= read -r -d '' ko; do
    rel=${ko#"$hw_build/modules/"}
    mkdir -p "$stage/hw-overlay/modules/$(dirname "$rel")"
    zstd --quiet -f -19 "$ko" -o "$stage/hw-overlay/modules/${rel}.zst"
done < <(find "$hw_build/modules" -name '*.ko' -type f -print0 | sort -z)

install -m644 "$tx3_tplg" "$stage/hw-overlay/firmware/Lenovo-Y700-tplg.bin"
install -m644 "$repo/packaging/microphone/Lenovo-Y700.conf" "$stage/hw-overlay/ucm2/Lenovo-Y700.conf"
install -m644 "$repo/packaging/microphone/HiFi-Mic.conf" "$stage/hw-overlay/ucm2/HiFi-Mic.conf"
install -m644 "$repo/packaging/microphone/Mic.conf" "$stage/hw-overlay/ucm2/Mic.conf"

cat > "$stage/hw-overlay/y700-hw-trial-watchdog.service" <<'UNIT'
[Unit]
Description=Y700 Hardware Trial 300s Auto-Return Watchdog
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'sleep 300; if [ ! -e /run/y700-hw-trial-disarm ]; then echo "y700-hw-trial: watchdog expired, rebooting to daily dev12.11" > /dev/kmsg; /usr/bin/systemctl --no-block reboot; fi'

[Install]
WantedBy=multi-user.target
UNIT

cp "$base_initrd" "$work/bundle/initrd"
size=$(stat -c %s "$work/bundle/initrd")
offset=$(( (size + 3) / 4 * 4 ))
truncate -s "$offset" "$work/bundle/initrd"

(
    cd "$stage"
    find . -exec touch -h -d @1795150416 {} +
    find . -mindepth 1 -printf '%P\n' | sort | cpio --quiet --reproducible --owner 0:0 -o -H newc
) >> "$work/bundle/initrd"

cp "$hw_build/kernel.efi" "$work/bundle/kernel.efi"
cp "$hw_build/board.dtb" "$work/bundle/board.dtb"
cp "$hw_build/notes" "$work/bundle/notes"

(
    cd "$work/bundle"
    sha256sum kernel.efi board.dtb initrd notes > SHA256SUMS
    sha256sum --strict -c SHA256SUMS
)

mv -nT "$work/bundle" "$out"
echo "HW_TRIAL_BUNDLE_READY dir=$out initrd_bytes=$(stat -c %s "$out/initrd")"
