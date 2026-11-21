#!/bin/bash
set -euo pipefail
[[ $# == 2 && -d $1 && ! -e $2 && ! -L $2 ]] || { echo 'Usage: build.sh ARM64_SDK_SYSROOT NEW_ELF' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
aarch64-linux-gnu-gcc --sysroot="$(realpath -e "$1")" -std=c11 -O2 -Wall -Wextra -Werror \
    "$here/offscreen.c" -o "$2" -lEGL -lGLESv2 -lgbm
sha256sum "$2"
