#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=${1:?pass the Linux build directory}
cd "$work/linux-7.3.4"
export ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-
uv run --no-project --python 3.12 python "$here/prepare-kernel.py" "$PWD"
scripts/config --set-str LOCALVERSION "-asphalt-prc" --disable LOCALVERSION_AUTO \
  --enable EXFAT_FS --enable NLS_UTF8 \
  --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE
make olddefconfig
# The upstream recipe requires the board's display, storage and radio choices.
sed -n 's/.*grep -q '\''\^\(CONFIG_[A-Z0-9_]*=[ym]\)\$'\''.*/\1/p' \
  "$here/../asphalt-upstream/pkgs/linux-kernel/sm8475/asphalt/default.nix" |
  while read -r option; do
    if [[ $option != CONFIG_MODULE_COMPRESS_XZ=y ]]; then grep -Fxq "$option" .config || { echo "missing $option"; exit 1; }; fi
  done
make -j"${JOBS:-12}" Image qcom/sm8475-lenovo-asphalt.dtb modules
make -j4 INSTALL_MOD_PATH="$work/modules" INSTALL_MOD_STRIP=1 modules_install
