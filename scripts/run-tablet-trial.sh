#!/bin/bash
# Start or resume a bounded trial with a previously reviewed non-default EFI entry.
set -euo pipefail
if [[ $# -lt 6 ]]; then
    echo "usage: $0 SSH_WRAPPER RUN_ID STATE_DIR ENTRY_STEM IMAGE_SHA256 NOTES_SHA256 [--check FILE] [--check-seconds N] [--startup-seconds N] [--exercise-timeout]" >&2
    exit 2
fi
bridge=$(realpath -e "$1")
id=$2; state=$(realpath -m "$3"); entry=$4; image=$5; notes=$6
shift 6
[[ $id =~ ^[a-z0-9][a-z0-9-]{0,39}$ && $entry =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]
[[ $image =~ ^[a-f0-9]{64}$ && $notes =~ ^[a-f0-9]{64}$ ]]
opts=()
while (( $# )); do
    case "$1" in
        --check) [[ $# -ge 2 && -f $2 && -r $2 && -s $2 ]]; bash -n "$2"; opts+=("$1" "$2"); shift 2 ;;
        --check-seconds) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]{0,3}$ ]] && (( $2 >= 25 && $2 <= 3600 )) || exit 2; opts+=("$1" "$2"); shift 2 ;;
        --startup-seconds) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]{0,3}$ ]] && (( $2 >= 60 && $2 <= 3600 )) || exit 2; opts+=("$1" "$2"); shift 2 ;;
        --exercise-timeout) opts+=("$1"); shift ;;
        *) echo "Unknown trial option: $1" >&2; exit 2 ;;
    esac
done
script_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p -m700 "$state"
exec 8>"$state/launch.lock"
flock -n 8
if [[ ! -e $state/state.json ]]; then
    status=$(timeout 15 bash "$bridge" "/usr/local/libexec/y700-lab-device status" </dev/null)
    read -r current _ <<< "$status"
    if [[ $current == none ]]; then
        timeout 40 bash "$bridge" "/usr/local/libexec/y700-lab-device arm $id $entry $image $notes" </dev/null
    elif [[ $current != "$id" ]]; then
        echo "Another tablet trial is active" >&2
        exit 1
    fi
fi
exec "${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.12}" python \
    "$script_dir/monitor-tablet-trial.py" "$bridge" "$id" "$state" "$notes" "${opts[@]}"
