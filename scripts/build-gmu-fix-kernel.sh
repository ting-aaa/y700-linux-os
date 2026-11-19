#!/bin/bash
# Build the one-change A730 test kernel from an independent copy of the compiled PRC baseline.
set -euo pipefail
src=$(realpath -e "${1:?compiled baseline Linux tree}")
out=$(realpath -m "${2:?new native Linux build directory}")
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ $out != "$src" && $out != "$src/"* ]]
(cd "$src" && sha256sum -c <<'INPUTS'
9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  arch/arm64/boot/Image
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
5944b93f6efcf9905423c1a40ac12315d16cefcb092cf133d572766b1d8ee634  drivers/gpu/drm/msm/adreno/a6xx_gmu.c
3a545bcb6baf2505384b5cfd2e32464e5b8de04686af51d77a00917bb7d5343d  drivers/gpu/drm/msm/adreno/a6xx_hfi.c
INPUTS
)
mkdir -m700 "$out"
cp -a --reflink=auto "$src" "$out/kernel"
cd "$out/kernel"
git apply --check "$repo/config/kernel/asphalt-hfi-match-queued-vote.patch"
git apply "$repo/config/kernel/asphalt-hfi-match-queued-vote.patch"
cmp "$src/drivers/gpu/drm/msm/adreno/a6xx_gmu.c" drivers/gpu/drm/msm/adreno/a6xx_gmu.c
bash "$repo/tests/gmu-queued-vote-replay.sh" "$PWD" | tee "$out/replay.log"
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-18 00:00:00 UTC'
make -j"${JOBS:-8}" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- Image > "$out/build.log" 2>&1
cmp "$src/.config" .config
awk '$3 == "vmlinux"' "$src/Module.symvers" | LC_ALL=C sort > "$out/baseline-exports"
LC_ALL=C sort vmlinux.symvers > "$out/candidate-exports"
cmp "$out/baseline-exports" "$out/candidate-exports"
cmp "$src/include/config/kernel.release" include/config/kernel.release
llvm-objcopy --dump-section .notes="$out/notes" --only-section=.notes vmlinux "$out/notes.elf"
sha256sum arch/arm64/boot/Image "$out/notes"
readelf -n vmlinux | grep 'Build ID:'
