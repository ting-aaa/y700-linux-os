#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
case ${1:-same} in
    same) rejoin=1 ;;
    alternate) rejoin=2 ;;
    crossband) rejoin=3 ;;
    *) echo 'Usage: run.sh [same|alternate|crossband]' >&2; exit 2 ;;
esac
export WIFI_SECURITY=sae WIFI_ACTOR=seat WIFI_ATTEMPT=fresh WIFI_REJOIN=$rejoin
exec bash "$here/../wifi-chooser/run-vm.sh"
