#!/usr/bin/env bash
set -euo pipefail

kernel=$(realpath "${1:?compiled Linux 7.3.4 source tree}")
out=${2:?new output directory}
fixture=$(cd -- "$(dirname -- "$0")" && pwd)
source=drivers/i2c/busses/i2c-qcom-cci.c

printf '%s  %s\n' 45b2dc46ea637f411a39f9352156e91d85a191b4fd3d2bfb44d5b7fc81d57693 \
    "$kernel/$source" | sha256sum --strict -c
mkdir -- "$out"
out=$(realpath "$out")
mkdir -p -- "$out/$(dirname -- "$source")"
cp -- "$kernel/$source" "$out/$source"
(cd -- "$out" && git apply --whitespace=error "$fixture/combined-read.patch")

# Compile the actual ISR, queue programming, transfer selector and FIFO path.
awk '/^#define CCI_HW_VERSION/{emit=1} /^struct hw_params /{exit} emit' \
    "$out/$source" >"$out/cci-defs.h"
awk '/^static irqreturn_t cci_isr\(/{emit=1} /^static int cci_halt\(/{emit=0}
     /^static int cci_run_queue\(/{emit=1} /^static u32 cci_func\(/{exit} emit' \
    "$out/$source" >"$out/cci-functions.h"
awk '/^#define I2C_M_[A-Z_]+[[:space:]]/' \
    "$kernel/include/uapi/linux/i2c.h" >"$out/i2c-flags.h"

flags=(-O2 -Wall -Wextra -Werror -Wno-unused-parameter -I "$out")
"${CC:-cc}" "${flags[@]}" "$fixture/queue-test.c" -o "$out/queue-test"
"$out/queue-test"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" "${flags[@]}" -static "$fixture/queue-test.c" \
    -o "$out/queue-test-arm64"
"${QEMU_AARCH64:-qemu-aarch64}" "$out/queue-test-arm64"

# Replay Kbuild's recorded C compiler invocation with its input, object and
# dependency file redirected to the new output directory.
uv run --offline --no-project --python /usr/bin/python3 python -B - "$kernel" "$out" "$source" <<'PY'
from pathlib import Path
import shlex
import subprocess
import sys

kernel, out, source = map(Path, sys.argv[1:])
obj = source.with_suffix('.o')
saved = kernel / obj.with_name(f'.{obj.name}.cmd')
command = shlex.split(saved.read_text().splitlines()[0].split(' := ', 1)[1])
if ';' in command:
    command = command[:command.index(';')]
for name in (source, obj):
    command[command.index(str(name))] = str(out / name)
dep = next(arg for arg in command if arg.startswith('-Wp,-MMD,'))
command[command.index(dep)] = f'-Wp,-MMD,{out / "i2c-qcom-cci.d"}'
subprocess.run(command, cwd=kernel, check=True)
PY
header=$(LC_ALL=C aarch64-linux-gnu-readelf -h "$out/${source%.c}.o")
grep -Eq 'Type:[[:space:]]+REL[[:space:]]' <<<"$header"
grep -Eq 'Machine:[[:space:]]+AArch64$' <<<"$header"
printf '%s\n' "$header"
