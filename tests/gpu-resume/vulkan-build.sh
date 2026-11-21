#!/bin/bash
set -euo pipefail
[[ $# == 2 && -d $1 && ! -e $2 && ! -L $2 ]] || { echo 'Usage: vulkan-build.sh ARM64_VULKAN_SDK NEW_ELF' >&2; exit 2; }
sdk=$(realpath -e "$1")
here=$(cd "$(dirname "$0")" && pwd -P)
[[ -f $sdk/usr/include/vulkan/vulkan.h && -f $sdk/usr/lib/aarch64-linux-gnu/libvulkan.so.1 ]]
aarch64-linux-gnu-gcc -std=c11 -O2 -Wall -Wextra -Werror -I"$sdk/usr/include" "$here/vulkan.c" \
    -L"$sdk/usr/lib/aarch64-linux-gnu" -Wl,-z,relro,-z,now -l:libvulkan.so.1 -o "$2"
sha256sum "$2"
