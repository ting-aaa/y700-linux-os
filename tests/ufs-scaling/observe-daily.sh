#!/bin/bash
# Observe naturally occurring UFS transitions on the installed Y700 without changing its power policy.
set -euo pipefail
export LC_ALL=C
[[ $(id -u) == 0 && $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
grep -zFxq lenovo,asphalt /proc/device-tree/compatible
ctl=/sys/bus/platform/devices/1d84000.ufshc
freq=/sys/class/devfreq/1d84000.ufshc
dbg=/sys/kernel/debug/ufshcd/1d84000.ufshc
clock=/sys/kernel/debug/clk/clk_summary
target=$(realpath -e /dev/disk/by-partlabel/boot_b)
node=$(realpath -e "/sys/class/block/$(basename "$target")")
[[ $node == "$(realpath -e "$ctl")"/* && -b $target && $(cat "$node/size") == 196608 ]]
grep -Fxq PARTNAME=boot_b "$node/uevent"
[[ $(cat "$node/partition") == 41 ]]
expected=4316fe356d9244f97b0623abc1e6fc820b295738af24fbe0f3a0f82482d07cad
trace=$(mktemp -d /sys/kernel/tracing/instances/y700-ufs-read.XXXXXXXX)
cleanup() {
    echo 0 >"$trace/tracing_on"
    echo 0 >"$trace/events/enable"
    rmdir -- "$trace"
}
trap cleanup EXIT
echo 0 >"$trace/tracing_on"
echo 32 >"$trace/buffer_size_kb"
for event in ufshcd_clk_scaling ufshcd_clk_gating ufshcd_profile_hibern8 ufshcd_runtime_suspend ufshcd_runtime_resume ufshcd_uic_command; do
    echo 1 >"$trace/events/ufs/$event/enable"
done
state() {
    printf 'STATE %s runtime=%s link=%s gear=%s clocks_Hz=' "$1" "$(cat "$ctl/power/runtime_status")" "$(cat "$ctl/power_info/link_state")" "$(cat "$ctl/power_info/gear")"
    awk '$1=="gcc_ufs_phy_axi_clk" || $1=="gcc_ufs_phy_unipro_core_clk" || $1=="gcc_ufs_phy_ice_core_clk" {printf "%s:%s ",$1,$5}' "$clock"
    printf 'devfreq_Hz=%s active_ms=%s suspended_ms=%s\n' "$(cat "$freq/cur_freq")" "$(cat "$ctl/power/runtime_active_time")" "$(cat "$ctl/power/runtime_suspended_time")"
}
errors() {
    awk -F': ' '/: [0-9]+$/ {print $1 "=" $2}' "$dbg/stats"
}
direct_read() {
    local begin end digest
    begin=$(date +%s%N)
    digest=$(dd if="$target" bs=65536 count=1 iflag=direct,fullblock status=none | sha256sum)
    end=$(date +%s%N)
    [[ $digest == "$expected  -" && $end -ge $begin ]]
    printf 'READ index=%d bytes=65536 sha256_match=1 read_and_hash_us=%d\n' "$1" "$(( (end-begin)/1000 ))"
}
printf 'POLICY min_Hz=%s max_Hz=%s available_Hz="%s" idle_hibern8_us=%s clock_gating_delay_ms=%s runtime_policy=%s\n' "$(cat "$freq/min_freq")" "$(cat "$freq/max_freq")" "$(cat "$freq/available_frequencies")" "$(cat "$ctl/auto_hibern8")" "$(cat "$ctl/clkgate_delay_ms")" "$(cat "$ctl/power/control")"
before=$(errors)
state before
echo 1 >"$trace/tracing_on"
for i in 1 2 3; do
    sleep 3
    direct_read "$i"
done
echo 0 >"$trace/tracing_on"
state after
after=$(errors)
if [[ $before == "$after" ]]; then echo 'ERRORS changed=0'; else echo 'ERRORS changed=1'; fi
printf '%s\n' "$after"
# Only fixed event types, UIC enter/exit opcodes and error counts leave the tablet.
awk '
/ufshcd_clk_gating:/ {gate[$NF]++}
/ufshcd_clk_scaling:/ {scale++}
/ufshcd_profile_hibern8:/ {profile++; if ($NF!="0") errors++}
/ufshcd_runtime_suspend:/ {susp++; if ($NF!="0") errors++}
/ufshcd_runtime_resume:/ {res++; if ($NF!="0") errors++}
/ufshcd_uic_command: (send_req|complete_rsp):/ && /cmd: 0x(17|18),/ {for(i=1;i<=NF;i++)if($i=="cmd:"){cmd=$(i+1); if(/complete_rsp:/) completed[cmd]++; else issued[cmd]++}}
END {
 for(s in gate) if(s ~ /^(CLKS_ON|CLKS_OFF|REQ_CLKS_ON|REQ_CLKS_OFF)$/) print "GATE " s "=" gate[s];
 printf "TRACE scaling=%d hibern8_profiles=%d runtime_suspend=%d runtime_resume=%d profiled_errors=%d h8_enter_sent=%d h8_enter_completed=%d h8_exit_sent=%d h8_exit_completed=%d\n",scale,profile,susp,res,errors,issued["0x17,"],completed["0x17,"],issued["0x18,"],completed["0x18,"]
}' "$trace/trace"
awk -F: '/^overrun:|^dropped events:/ {n+=$2} END{print "TRACE_LOSS overwritten_or_dropped=" n+0}' "$trace"/per_cpu/cpu*/stats
[[ $before == "$after" ]]
