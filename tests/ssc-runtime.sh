#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
ssc=$repo/src/sensors/ssc
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/defaults/registry" "$work/state" "$work/bin"
printf 'version=7\0' > "$work/defaults/sns_reg_version"
printf '%s\n' '{"fixture":{"data":1}}' > "$work/defaults/registry/fixture"

bash "$ssc/seed" "$work/defaults" "$work/state" &
first=$!
bash "$ssc/seed" "$work/defaults" "$work/state" &
second=$!
wait "$first"
wait "$second"
diff -r "$work/defaults" "$work/state/registry"
printf '%s\n' '{"fixture":{"data":2}}' > "$work/state/registry/registry/fixture"
cp "$work/state/registry/registry/fixture" "$work/calibration"
bash "$ssc/seed" "$work/defaults" "$work/state"
cmp "$work/calibration" "$work/state/registry/registry/fixture"

mkdir "$work/unsafe-state"
ln -s "$work/state/registry" "$work/unsafe-state/registry"
if bash "$ssc/seed" "$work/defaults" "$work/unsafe-state" 2>/dev/null; then
    echo 'Seeding unexpectedly accepted a symbolic registry path.' >&2
    exit 1
fi

cat > "$work/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift 3
exec "$@"
EOF
cat > "$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$work/bin/ssccli" <<'EOF'
#!/usr/bin/env bash
printf '.\n' >> "$SSC_TEST_CALLS"
if [[ $SSC_TEST_SAMPLE == present && $(wc -l < "$SSC_TEST_CALLS") == 2 ]]; then
    printf 'Accelerometer sensor measurement: X=0.0 Y=9.8 Z=0.0\n'
fi
EOF
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH" SSC_TEST_CALLS="$work/calls" SSC_TEST_SAMPLE=present
bash "$ssc/wait-accelerometer"
[[ $(wc -l < "$SSC_TEST_CALLS") == 2 ]]

export SSC_TEST_SAMPLE=absent
: > "$SSC_TEST_CALLS"
if bash "$ssc/wait-accelerometer" 2>/dev/null; then
    echo 'Readiness passed without an accelerometer sample.' >&2
    exit 1
fi
[[ $(wc -l < "$SSC_TEST_CALLS") == 6 ]]
printf '%s\n' 'SSC registry seeding, calibration retention, symlink rejection and sample readiness passed.'
