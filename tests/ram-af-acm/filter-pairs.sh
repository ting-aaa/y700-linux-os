#!/usr/bin/env bash
# The v2 filter first removes libcamera log decoration and checks the existing receipt types.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
ppm='(0|[1-9][0-9]{0,7})'
phase='(coarse|fine|verify)'
pair="^AF_DIAG phase=$phase point=([1-9]) mean_ppm=$ppm pair_delta_ppm=$ppm ref_mean_ppm=$ppm ref_pair_delta_ppm=$ppm$"
terminal="^AF_DIAG phase=$phase reason=[a-z-]+ input=[a-z-]+ lens_api_status=-?[0-9]+ controls=[0-9]+/[0-9]+/[0-9]+ samples=[0-9]+/[0-9]+/[0-9]+ timestamp_rejects=[0-9]+/[0-9]+/[0-9]+$"
bash "$here/filter-aggregates.sh" | while IFS= read -r line; do
    if [[ $line == 'AF_DIAG '* ]] && [[ ! $line =~ $terminal ]]; then
        [[ $line =~ $pair ]] || continue
        [[ ${BASH_REMATCH[1]} != verify || ${BASH_REMATCH[2]} == 1 ]] || continue
        # sqrt(mean(squared green gradient)) / max(12, mean green) <= 255 / 12.
        (( BASH_REMATCH[3] <= 21250000 && BASH_REMATCH[4] <= 21250000 &&
           BASH_REMATCH[5] <= 21250000 && BASH_REMATCH[6] <= 21250000 )) || continue
    fi
    printf '%s\n' "$line"
done
