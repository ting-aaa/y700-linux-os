#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
cd /opt/panel-test
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.qcam_virtual_fixture=1 /proc/cmdline
[[ $(cat /sys/block/vda/ro) == 1 && ! -e /opt/qcam-virtual ]]
ln -s /opt/panel-test /opt/qcam-virtual
insmod ./vkms.ko enable_writeback=0
[[ $(cat /sys/class/drm/card0-DSI-1/status) == connected ]]
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix
export DISPLAY=:22 XAUTHORITY=/run/qcam-xauth
umask 077
{ printf '\377\377\000\000\000\00222\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c16 /dev/urandom; } > "$XAUTHORITY"
chown y700 "$XAUTHORITY"
cat > /run/qcam-screen.conf <<'XORG'
Section "ServerFlags"
 Option "AutoAddDevices" "false"
 Option "AutoAddGPU" "false"
EndSection
Section "Device"
 Identifier "display"
 Driver "modesetting"
 Option "kmsdev" "/dev/dri/card0"
 Option "AccelMethod" "none"
 Option "ShadowFB" "true"
EndSection
Section "Screen"
 Identifier "only"
 Device "display"
 Subsection "Display"
   Virtual 3072 3072
 EndSubsection
EndSection
XORG
/usr/lib/xorg/Xorg "$DISPLAY" vt1 -auth "$XAUTHORITY" -nolisten tcp -noreset -novtswitch \
    -config /run/qcam-screen.conf -logfile /run/qcam-xorg.log >/run/qcam-xstderr 2>&1 &
xpid=$!
trap 'rc=$?; kill "$xpid" 2>/dev/null || :; if (( rc )); then tail -n 22 /run/qcam-xorg.log; fi' EXIT
for _ in {1..100}; do kill -0 "$xpid"; if xrandr --current > /run/qcam-outputs 2>/dev/null; then break; fi; sleep .15; done
grep -F 'DSI-1 connected' /run/qcam-outputs
grep -Fq 'Loading /usr/lib/xorg/modules/drivers/modesetting_drv.so' /run/qcam-xorg.log
xrandr --newmode 1600x2560-fixture 349.32 1600 1728 1896 2192 2560 2563 2573 2656 -HSync +VSync
xrandr --addmode DSI-1 1600x2560-fixture
xrandr --output DSI-1 --mode 1600x2560-fixture --rotate left
umask 022
bash ./virtual-guest.sh
