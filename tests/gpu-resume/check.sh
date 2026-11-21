#!/bin/bash
# Observe the ordinary user's offscreen GPU before and after a separately managed sleep.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
die() { echo "GPU_PHASE_FAILED $*" >&2; exit 1; }
[[ $EUID == 0 && $# == 3 && ( $1 == before || $1 == after ) ]] ||
    die 'usage as root: check.sh before|after PRIVATE_RESULTS PROBE'
stage=$1
out=$(realpath -m "$2")
elf=$(realpath -e "$3")
[[ -f $elf && -x $elf && $(uname -m) == aarch64 && $(id -u y700) == 1000 ]] || die 'unexpected ELF, arch or user'
grep -azFxq lenovo,asphalt /proc/device-tree/compatible || die 'unexpected board'
hash=$(sha256sum "$elf" | cut -d' ' -f1)
if [[ $stage == before ]]; then mkdir -m700 "$out"; fi
[[ -d $out && ! -L $2 && $(stat -c '%u:%g:%a' "$out") == 0:0:700 ]] || die 'unexpected results directory'
exec 9<"$out"
flock -nx 9 || die 'another observation is active'
[[ ! -e $out/$stage.log ]] || die 'this phase was already attempted'
exec > >(tee "$out/$stage.log") 2>&1
boot=$(cat /proc/sys/kernel/random/boot_id)
faults='HFI vote snapshot|GPU_SET.*tim(e|ed) ?out|Timeout waiting for GMU OOB set GPU_SET|GX_BW_PERF_VOTE.*(timed out|returned error)|gpu fault|hangcheck detected|preemption timed out|GMU firmware (fault|error)|Unexpected message id .*response queue|arm-smmu.*(translation fault|Unhandled context fault)|ring .*timeout|GPU.*recovering|[[]dpu error[]]|flip_done timed out|vblank timeout|vblank wait timed out|hw recovery is not complete for ctl:|cleanup reset failed, ctl='
# Store counts only; the journal can also contain unrelated user/device data.
counts() {
    journalctl -k -b -q --no-pager -o cat "$@" |
        awk -v f="$faults" 'tolower($0) ~ tolower(f) {bad++}
            /PM: suspend entry/ {enter++} /PM: suspend exit/ {leave++}
            END {print bad+0, enter+0, leave+0}'
}
cursor() {
    journalctl -k -b -q -n1 --show-cursor --no-pager -o cat | sed -n 's/^-- cursor: //p'
}
suspend_ms() {
    perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,CLOCK_BOOTTIME -e \
        'printf "%.0f\n",1000*(clock_gettime(CLOCK_BOOTTIME)-clock_gettime(CLOCK_MONOTONIC))'
}

if [[ $stage == before ]]; then
    seen=$(counts)
    read -r faults_seen _ <<<"$seen"
    ((faults_seen == 0)) || die 'kernel has a GPU or display fault on this boot'
    echo "$boot" >"$out/boot"
    echo "$hash" >"$out/elf.sha256"
else
    [[ -f $out/before.ok && $(cat "$out/boot") == "$boot" && $(cat "$out/elf.sha256") == "$hash" ]] ||
        die 'incomplete baseline, changed boot or changed probe'
    since=$(cat "$out/after-before.cursor")
    [[ -n $since ]] || die 'missing prior journal cursor'
    seen=$(counts --after-cursor="$since")
    read -r faults_seen enter leave <<<"$seen"
    ((faults_seen == 0)) || die 'GPU or display fault since pre-sleep completion'
    previous=$(cat "$out/suspend-ms")
    now=$(suspend_ms)
    elapsed=$((now-previous))
    printf 'GPU_SLEEP entered=%d exited=%d timekeeping_suspended_ms=%d same_boot=1\n' "$enter" "$leave" "$elapsed"
fi
start=$(cursor)
[[ -n $start ]] || die 'kernel journal unavailable'
uid=$(id -u y700)
gid=$(id -g y700)
printf 'GPU_PHASE stage=%s uid=%s elf=%s\n' "$stage" "$uid" "$hash"
set +e
timeout -k2 20 setpriv --reuid="$uid" --regid="$gid" --init-groups --no-new-privs \
    env -i LC_ALL=C PATH=/usr/bin:/bin HOME=/nonexistent MESA_SHADER_CACHE_DISABLE=true "$elf"
rc=$?
set -e
sleep 0.3
seen=$(counts --after-cursor="$start")
read -r retired_faults _ <<<"$seen"
printf 'GPU_POSTCHECK stage=%s exit=%s new_kernel_faults=%s\n' "$stage" "$rc" "$retired_faults"
[[ $rc == 0 && $retired_faults == 0 && $(cat /proc/sys/kernel/random/boot_id) == "$boot" ]] ||
    die 'rendering or kernel health failed'
if [[ $stage == before ]]; then
    suspend_ms >"$out/suspend-ms"
    cursor >"$out/after-before.cursor"
    [[ -s $out/after-before.cursor ]] || die 'no final kernel cursor'
else
    (( enter > 0 && enter == leave && elapsed >= 100 )) || die 'post-render passed but completed system sleep was not established'
fi
echo "GPU_PHASE_PASS stage=$stage"
touch "$out/$stage.ok"
