#!/bin/bash
# Exercise supported OPP changes and runtime resume on the isolated Y700 trial.
set -euo pipefail
id=$(cat /var/lib/y700-lab/active)
grep -Fqw "y700.lab_trial=$id" /proc/cmdline
boot=$(cat /proc/sys/kernel/random/boot_id)
out=/var/lib/y700-lab/runs/$id/gmu-$boot
mkdir -m700 "$out"
gpu=/sys/class/devfreq/3d00000.gpu
control=$gpu/device/power/control
minimum=$(cat "$gpu/min_freq")
power=$(cat "$control")
trace=/sys/kernel/tracing/instances/y700-vote
pattern='HFI vote snapshot|GPU_SET.*tim(e|ed) ?out|Timeout waiting for GMU OOB set GPU_SET|GX_BW_PERF_VOTE.*(timed out|returned error)|gpu fault|hangcheck detected|preemption timed out|GMU firmware (fault|error)|Unexpected message id .*response queue|arm-smmu.*(translation fault|Unhandled context fault)|ring .*timeout|GPU.*recovering|\[dpu error\]|flip_done timed out|vblank timeout|vblank wait timed out|hw recovery is not complete for ctl:|cleanup reset failed, ctl='
journalctl -k -b -q --no-pager -o short-monotonic |
    { grep -Ei "$pattern" || [[ $? == 1 ]]; } > "$out/preflight-faults"
[[ ! -s $out/preflight-faults ]] || { cat "$out/preflight-faults"; exit 76; }
mkdir "$trace"
watcher=
reader=
start_cursor=$(journalctl -k -b -n 1 --show-cursor -o cat --no-pager | sed -n 's/^-- cursor: //p')
test -n "$start_cursor"
cleanup() {
    trap - ERR
    set +e
    echo 0 > "$trace/tracing_on"
    sleep 0.2
    if [[ -n $reader ]]; then kill "$reader"; wait "$reader"; fi
    if [[ -n $watcher ]]; then kill "$watcher"; wait "$watcher"; fi
    cat "$trace"/per_cpu/cpu*/stats > "$out/trace-stats"
    journalctl -k -b -o short-monotonic --no-pager > "$out/kernel.log"
    journalctl -k -b --after-cursor="$start_cursor" -o short-monotonic --no-pager -q \
        -g 'HFI queued vote ACK after missed MSGQ' > "$out/recovered-acks"
    echo "$minimum" > "$gpu/min_freq"
    echo "$power" > "$control"
    rmdir "$trace"
    grep -Ei "$pattern|echo_cmd=|HFI queued vote ACK|HFI IRQ cleared MSGQ" "$out/kernel.log" || true
    sync -f "$out"
}
trap cleanup EXIT
trap 'exit 124' TERM INT
# A new devfreq device may not have published the full operating range yet.
# Keep the original floor for restoration, and exercise two supported rates
# inside the limits actually reported by the driver.
for ((probe=0; probe<20; probe++)); do
    low=$(cat "$gpu/min_freq")
    high=$(cat "$gpu/max_freq")
    rates=$(cat "$gpu/available_frequencies")
    printf 'min=%s max=%s available=%s\n' "$low" "$high" "$rates" >> "$out/operating-range"
    mapfile -t opps < <(tr ' ' '\n' <<< "$rates" | awk -v lo="$low" -v hi="$high" \
        '/^[0-9]+$/ && $1+0>0 && $1+0>=lo+0 && $1+0<=hi+0 {print $1}' | sort -nu)
    (( ${#opps[@]} >= 2 )) && break
    sleep 1
done
if (( ${#opps[@]} < 2 )); then
    tail -1 "$out/operating-range" >&2
    exit 1
fi
echo 128 > "$trace/buffer_size_kb"
for event in drm_msm_gpu/msm_gmu_freq_change drm_msm_gpu/msm_gpu_suspend drm_msm_gpu/msm_gpu_resume; do
    echo 1 > "$trace/events/$event/enable"
done
cat "$trace/trace_pipe" > "$out/trace" &
reader=$!
journalctl -k -b -n all -f -q -o short-monotonic --no-pager -g "$pattern" > "$out/faults" &
watcher=$!
echo 1 > "$trace/tracing_on"
limit=$((SECONDS + ${Y700_CHECK_SECONDS:-25} - 9))
cycles=0
while (( SECONDS < limit )); do
    [[ ! -s $out/faults ]] || break
    kill -0 "$watcher" "$reader"
    printf 'wake %d\n' "$cycles" > "$trace/trace_marker"
    echo on > "$control"
    [[ $(cat "$gpu/device/power/runtime_status") == active ]]
    for ((i=0; i<32; i++)); do
        [[ ! -s $out/faults ]] || break
        echo "${opps[1]}" > "$gpu/min_freq"
        sleep 0.003
        echo "${opps[0]}" > "$gpu/min_freq"
        sleep 0.003
    done
    echo auto > "$control"
    sleep 0.1
    cycles=$((cycles+1))
    if [[ ${Y700_REQUIRE_QUEUED_ACK:-0} == 1 ]] && (( cycles % 10 == 0 )); then
        if [[ $(grep -c ' msm_gpu_resume:' "$out/trace" || true) -ge 10 ]] &&
           [[ $(grep -c ' msm_gpu_suspend:' "$out/trace" || true) -ge 10 ]] &&
           journalctl -k -b --after-cursor="$start_cursor" -q --no-pager -g 'HFI queued vote ACK after missed MSGQ' | grep . >/dev/null; then
            break
        fi
    fi
done
printf 'boot=%s cycles=%d OPP_Hz=%s,%s\n' "$boot" "$cycles" "${opps[0]}" "${opps[1]}" | tee "$out/summary"
journalctl -k -b -q --no-pager -o short-monotonic |
    { grep -Ei "$pattern" || [[ $? == 1 ]]; } > "$out/final-faults"
[[ ! -s $out/final-faults ]] || { cat "$out/final-faults"; exit 76; }
