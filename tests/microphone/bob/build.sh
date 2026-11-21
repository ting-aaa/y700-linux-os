#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: build.sh PREPARED_ASPHALT_KERNEL NEW_OUTPUT_DIR" >&2; exit 2; }
k=$(realpath -e "$1"); out=$(realpath -m "$2")
src=$(cd "$(dirname "$0")" && pwd)
[[ ! -e $out && ! -L $out ]]
printf '%s  %s\n' \
   48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83 "$k/Module.symvers" | sha256sum --strict -c -
w=$(mktemp -d)
trap 'rm -r --one-file-system -- "$w"' EXIT
install -m644 "$src/y700_bob_read.c" "$w/"
printf 'obj-m := y700_bob_read.o\n' > "$w/Makefile"
make -s -C "$k" ARCH=arm64 LLVM=1 M="$w" modules
[[ $(modinfo -F vermagic "$w/y700_bob_read.ko") == 7.3.4-asphalt-prc\ * ]]
nm -u "$w/y700_bob_read.ko" | awk '{print $2}' > "$w/imports"
for sym in rpmh_read cmd_db_read_addr cmd_db_read_slave_id; do grep -Fxq "$sym" "$w/imports"; done
if grep -E '(rpmh_write|regulator_(set|enable|disable)|regmap_(read|write)|spmi_|sdw_)' "$w/imports"; then exit 1; fi
mkdir -m 700 "$out"
install -m644 "$w/y700_bob_read.ko" "$w/imports" "$out/"
(cd "$out"; sha256sum y700_bob_read.ko imports > SHA256SUMS; cat SHA256SUMS)
