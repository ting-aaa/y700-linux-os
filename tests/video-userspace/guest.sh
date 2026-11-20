#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
grep -qw y700.video_userspace=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
[[ $(dpkg --print-architecture) == arm64 && -z $(compgen -G '/dev/video[0-9]*') ]]
dpkg-query -W y700-platform chromium libgstreamer1.0-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good
cd /opt/video-userspace
dpkg-deb -x dummy.deb /
export DISPLAY=:1 XDG_CURRENT_DESKTOP=XFCE XDG_RUNTIME_DIR=/run/video-user XAUTHORITY=/run/video-user/Xauthority
export UV_CACHE_DIR=$XDG_RUNTIME_DIR/uv UV_OFFLINE=1 PYTHONUNBUFFERED=1
install -d -m700 -o y700 -g y700 "$XDG_RUNTIME_DIR"
(
    printf '\377\377\000\000\000\0011\000\022MIT-MAGIC-COOKIE-1\000\020'
    head -c 16 /dev/urandom
) > "$XAUTHORITY"
chmod 600 "$XAUTHORITY"
chown y700:y700 "$XAUTHORITY"
mkdir -p /dev/shm /run/dbus
mount -t tmpfs -o mode=1777 tmpfs /dev/shm
ip link set lo up
dbus-daemon --system --fork
Xorg "$DISPLAY" -config /opt/video-userspace/dummy.conf -auth "$XAUTHORITY" -nolisten tcp -noreset \
    -logfile /run/video-xorg.log >/run/video-xorg.stderr 2>&1 & xorg=$!
trap 'kill "$xorg" 2>/dev/null || :' EXIT
for _ in {1..80}; do if xrandr -q >/dev/null 2>&1; then break; fi; sleep .1; done
xrandr -q >/dev/null
cp h264.mp4 hevc.mp4 vp9.webm player.html "$XDG_RUNTIME_DIR/"
if [[ -f expected.i420 ]]; then cp expected.i420 padded.nv12 "$XDG_RUNTIME_DIR/"; fi
cd "$XDG_RUNTIME_DIR"
py=(/opt/video-userspace/uv run --offline --no-project --python /usr/bin/python3 python -B)
if [[ -f /opt/video-userspace/player.tar.gz ]]; then
    mkdir -p /dev/pts
    mount -t devpts devpts /dev/pts
    ln -s /proc/self/fd /dev/fd
    tar -xzf /opt/video-userspace/player.tar.gz -C /tmp
    bash /tmp/y700-video-player/install.sh --install
    bash /tmp/y700-video-player/install.sh --check
    exec timeout -k 3 150 runuser -u y700 -- dbus-run-session -- bash /opt/video-userspace/session.sh
fi
timeout -k 3 65 runuser -u y700 -- "${py[@]}" /opt/video-userspace/gstreamer.py
runuser -u y700 -- unshare --user --map-root-user true
timeout -k 3 135 runuser -u y700 -- dbus-run-session -- "${py[@]}" /opt/video-userspace/desktop.py
