#!/usr/bin/env bash
# Undo exactly the nine UFS/GCC/ICE property changes, then compare the entire compiled tree.
set -euo pipefail
[[ $# == 2 ]]
before=$(realpath -e "$1"); after=$(realpath -e "$2")
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
ufs=/soc@0/ufshc@1d84000
ice=/soc@0/crypto@1d88000
gcc=/soc@0/clock-controller@100000
cp "$after" "$tmp/reverted.dtb"
restore() {
    local type=$1 node=$2 prop=$3
    local -a values
    read -ra values < <(fdtget -t "$type" "$before" "$node" "$prop")
    fdtput -t "$type" "$tmp/reverted.dtb" "$node" "$prop" "${values[@]}"
}
read -ra clocks < <(fdtget -tx "$after" "$ufs" clocks)
[[ ${#clocks[@]} == 18 && "${clocks[*]:0:16}" == "$(fdtget -tx "$before" "$ufs" clocks)" ]]
restore x "$gcc" power-domains
for prop in assigned-clocks assigned-clock-rates required-opps; do
    fdtput -d "$tmp/reverted.dtb" "$ice" "$prop"
done
restore s "$ufs" clock-names
restore x "$ufs" clocks
restore x "$ufs" required-opps
for rate in 75000000 850000000; do
    restore x "$ufs/opp-table/opp-$rate" opp-hz
done
dtc -q -s -I dtb -O dts "$before" > "$tmp/before.dts"
dtc -q -s -I dtb -O dts "$tmp/reverted.dtb" | cmp "$tmp/before.dts" -
echo 'UFS_DTB_DELTA properties=9 original_clock_ids=8 full_tree_reverted=identical'
