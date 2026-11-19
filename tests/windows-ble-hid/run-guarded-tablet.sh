#!/bin/bash
set -euo pipefail
wrapper=$1
runtime=$2
marker=$3
address=$4
[[ $runtime =~ ^/run/y700-pair-[a-f0-9]{32}$ ]]
[[ $marker =~ ^([0-9]{1,3}-){7}[0-9]{1,3}$ && $address =~ ^[A-F0-9]{12}$ ]]
cd -- "$(dirname -- "$0")"
transfer="umask 077; mkdir -m 700 -- '$runtime' && mkdir -m 700 -- '$runtime/src' && tar -xf - -C '$runtime/src'"
tar -cf - tablet-probe.py guarded-pair.py capture-input.py | bash "$wrapper" "$transfer"
bash "$wrapper" bash -s -- "$runtime" "$marker" "$address" <<'TABLET'
set -eu
runtime=$1
marker=$2
address=$3
test "$(stat -c '%u:%a' "$runtime")" = 0:700
cd "$runtime/src"
reader=
cleanup() {
    if [ -n "$reader" ]; then kill "$reader" 2>/dev/null || true; wait "$reader" 2>/dev/null || true; fi
    rm -f -- "$runtime"/{linux-code,windows-code,input-ready,input-done,peer-address,guard-started,capture-lock,abort}
    rm -f -- "$runtime/src"/{tablet-probe.py,guarded-pair.py,capture-input.py}
    cd /
    rmdir -- "$runtime/src" "$runtime"
}
trap cleanup EXIT
export PYTHONDONTWRITEBYTECODE=1
runpy=(uv run --offline --no-project --python /usr/bin/python3 python -B -u)
"${runpy[@]}" capture-input.py --runtime "$runtime" --host-address "$address" &
reader=$!
for _ in {1..50}; do
    [ ! -e "$runtime/capture-lock" ] || break
    kill -0 "$reader" || exit 1
    sleep .1
done
test -e "$runtime/capture-lock"
"${runpy[@]}" guarded-pair.py "$marker" --runtime "$runtime" --host-address "$address"
TABLET
