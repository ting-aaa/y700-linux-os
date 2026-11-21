#!/bin/bash
# Prepare the private RAM-only observer, using the previously validated early USB stack.
set -euo pipefail
umask 077
export LC_ALL=C
[[ $# == 3 ]] || { echo 'Usage: build-observer.sh VERIFIED_RECEIVER_INITRD PRIVATE_BOOT_B_GUID NEW_DIRECTORY' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
input=$(realpath -e "$1"); guid=$(realpath -e "$2"); out=$(realpath -m "$3")
[[ ! -e $out && ! -L $out ]]
echo "f297cf42f2c387a6f3b4521f2bdba61c9762364c8bc46565981e936db2f620fc  $input" | sha256sum --status -c -
[[ $(wc -c < "$guid") == 37 ]]
grep -Exq '[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}' "$guid"
w=$(mktemp -d "$(dirname "$out")/.ufs-observer.XXXXXXXX")
trap 'rm -r --one-file-system -- "$w"' EXIT
mkdir -p "$w/root"/{dev,proc,sys,modules} "$w/out"
install -m400 "$guid" "$w/root/board-guid"
# First member is the original gzip/newc; the private receiver appends its USB module cpio.
"${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python -B - "$input" "$w" <<'PY'
from pathlib import Path
import sys
import zlib
root = Path(sys.argv[2])
stream = zlib.decompressobj(31)
original = stream.decompress(Path(sys.argv[1]).read_bytes()) + stream.flush()
assert stream.eof and original.startswith(b"070701")
tail = stream.unused_data.lstrip(b"\0")
assert tail.startswith(b"070701")
(root / "base.cpio").write_bytes(original)
(root / "extra.cpio").write_bytes(tail)
PY
(cd "$w/root" && cpio --quiet -id --no-absolute-filenames 'lib/firmware/qcom/sm8475/lenovo/tb320fc/adsp.*' < "$w/base.cpio")
[[ -s $w/root/lib/firmware/qcom/sm8475/lenovo/tb320fc/adsp.mdt ]]
for name in qcom_glink_smem aux-hpd-bridge fsa4480 pmic_glink pmic_glink_altmode typec_ucsi ucsi_glink; do
    cpio --quiet -i --to-stdout "ram-receive/modules/$name.ko" < "$w/extra.cpio" > "$w/root/modules/$name.ko"
    [[ -s $w/root/modules/$name.ko ]]
done
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -static -Os -Wall -Wextra -Werror -Wl,--build-id=none -s \
    "$here"/observer-{init,io,port,storage}.c -o "$w/root/init"
(cd "$w/root"; find . -type d -exec chmod 755 {} +; find . -type f ! -name init -exec chmod 400 {} +
 chmod 755 init; find . -exec touch -h -d @1795150416 {} +
 find . -print0 | sort -z | cpio --null --quiet --reproducible --owner 0:0 -o -H newc | gzip -n -6 > "$w/out/initrd")
(cd "$w/out"; sha256sum initrd > SHA256SUMS; wc -c initrd; cat SHA256SUMS)
mv -T --no-clobber "$w/out" "$out"; [[ ! -e $w/out ]]
