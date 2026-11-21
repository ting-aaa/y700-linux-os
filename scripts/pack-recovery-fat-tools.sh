#!/bin/bash
# Extract the checked ARM64 dosfstools runtime, without mounting the source image.
set -euo pipefail
umask 022
[[ $# == 2 ]] || { echo 'Usage: pack-recovery-fat-tools.sh SEALED_ROOT APPEND_DIR' >&2; exit 2; }
root=$(realpath -e -- "$1")
append=$(realpath -e -- "$2")
[[ -f $root && -d $append && ! -e $append/y700-fat-tools && ! -L $append/y700-fat-tools ]]
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-boot-fat-tools.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
mkdir -p "$work/payload/gconv"
cd "$work"
extract() {
    local path=$1 dest=$2 sum=$3
    debugfs -R "dump $path $dest" "$root" >/dev/null 2>debugfs.log
    printf '%s  %s\n' "$sum" "$dest" | sha256sum --quiet --strict -c -
}
lib=/usr/lib/aarch64-linux-gnu
extract /usr/sbin/fsck.fat payload/fsck.fat 2d683277fec9e27db145ebb65cc1f15695e6a395a9e238c693a1083b7bf75ad7
extract "$lib/ld-linux-aarch64.so.1" payload/ld-linux-aarch64.so.1 1b882eddacd494b060413a8aa4f0a4754ee3f84775e68cecbf8a86092b59cca6
extract "$lib/libc.so.6" payload/libc.so.6 70fa4c4cf57eabeb96097cce47582d02379c4cd1de3db3e98ade4dd7089a1b13
extract "$lib/gconv/IBM850.so" payload/gconv/IBM850.so e4ea1246ae63cd6eb8dd58d904bd6d04dd1c421eb07a63ee3bafa739a06569d6
extract "$lib/gconv/gconv-modules.d/gconv-modules-extra.conf" modules efd92404c912b44689b96e311c2d827944c54df21f1509985d122495bda6f9aa
grep -F 'IBM850//' modules > payload/gconv/gconv-modules
echo '5b2bbae340520f9c8c9096393168b4b9947b5ab3f3fccedef425e73a4bfe62cc  payload/gconv/gconv-modules' | sha256sum --quiet --strict -c -
chmod 0755 payload payload/gconv payload/fsck.fat payload/ld-linux-aarch64.so.1
chmod 0644 payload/libc.so.6 payload/gconv/*
find payload -exec touch -d @1795150416 {} +
mv -nT -- payload "$append/y700-fat-tools"
[[ ! -e payload ]]
