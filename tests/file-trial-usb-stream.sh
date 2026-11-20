#!/usr/bin/env bash
# Stream the two sealed payloads over pinned USB SSH. No files are created on the tablet.
set -euo pipefail
export LC_ALL=C
[[ $# == 2 ]] || { echo 'Usage: file-trial-usb-stream.sh USB_SSH_WRAPPER EXTRACTED_BUNDLE_BASE' >&2; exit 2; }
ssh=$(realpath -e -- "$1")
base=$(realpath -e -- "$2")
cd "$base"
sha256sum --quiet --strict -c SHA256SUMS
state='set -eu; p=${SSH_CONNECTION%% *}; case " $(ip -o route get "$p") " in *" dev usb0 "*) ;; *) exit 1;; esac; test "$(cat /etc/y700/image-id)" = asphalt-prc-debian13-xfce-7.3.4-v1; cat /proc/sys/kernel/random/boot_id; findmnt -nro SOURCE /; findmnt -nro SOURCE /boot'
before=$(bash "$ssh" "$state")
[[ -n $before ]]
begin=$SECONDS
total=0
for file in root.ext4 linux-boot.fat; do
    case $file in
        root.ext4) expected=041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6 ;;
        linux-boot.fat) expected=495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 ;;
    esac
    result=$(bash "$ssh" "runuser -u y700 -- bash -o pipefail -c 'test \$(id -u) = 1000 && zstd -qdc | sha256sum'" < "$file.zst")
    [[ $result == "$expected  -" ]]
    size=$(stat -c %s "$file.zst")
    total=$((total + size))
    printf 'USB_RAM_STREAM file=%s compressed_bytes=%d sha256=%s\n' "$file" "$size" "$expected"
done
after=$(bash "$ssh" "$state")
[[ $after == "$before" ]]
printf 'USB_RAM_STREAM_PASS interface=usb0 desktop_uid=1000 compressed_bytes=%d raw_bytes=7516192768 wall_seconds=%d boot_and_mounts=unchanged\n' "$total" "$((SECONDS - begin))"
