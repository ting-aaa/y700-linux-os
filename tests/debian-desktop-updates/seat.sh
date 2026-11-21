#!/bin/bash
set -euo pipefail
log=/run/topology/user/gui.log
install -o y700 -g y700 -m600 /dev/null "$log"
rc=0
systemd-run --quiet --wait --collect --unit=y700-updater-gui.service -p User=y700 -p PAMName=login \
    -p StandardInput=tty -p TTYPath=/dev/tty1 -p StandardOutput="append:$log" -p StandardError="append:$log" \
    -p WorkingDirectory=/opt/y700-topology -E XDG_SESSION_TYPE=x11 -E XDG_SESSION_CLASS=user \
    -E XDG_SEAT=seat0 -E XDG_VTNR=1 -E "DISPLAY=$DISPLAY" -E "XAUTHORITY=$XAUTHORITY" \
    /bin/bash /opt/y700-topology/session.sh || rc=$?
cat "$log"
exit "$rc"
