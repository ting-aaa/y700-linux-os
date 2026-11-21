#!/usr/bin/env bash
set -eu
ip link set lo up
mkdir -p /run/dbus
dbus-uuidgen > /etc/machine-id
dbus-daemon --system --fork
runuser -u y700 -- unshare --user --map-root-user true
if [[ -f ./pipewire.deb ]]; then
    dpkg-deb -x ./pipewire.deb /
    dpkg-deb -f ./pipewire.deb Package Version
    sha256sum ./pipewire.deb /usr/libexec/y700-camera-orientation
else
    dpkg-query -W y700-camera-pipewire
fi
sha256sum /usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
# Debian's virtual libcamera pipeline has no backing dev_t. WirePlumber
# expects device.devids for its V4L2/libcamera deduplication. There are no
# V4L2 devices in this fixture, so advertise the empty device-number list.
hook=/usr/share/wireplumber/scripts/monitors/libcamera/create-device.lua
[[ $(grep -Fc '  mutils:register_cam_node (parent, id, factory, properties)' "$hook") == 1 ]]
sed -i '/^  mutils:register_cam_node /i\  properties["device.devids"] = properties["device.devids"] or "[]"' "$hook"
# The sandbox makes some renderer process records unreadable by its caller.
# The external root observer reads status fields inside this otherwise empty VM.
(
    for _ in {1..550}; do [[ -f /run/qcam-qa/check-sandbox ]] && break; sleep 1; done
    [[ -f /run/qcam-qa/check-sandbox ]]
    browser=$(pgrep -u y700 -xo chromium)
    for renderer in $(pgrep -u y700 -f '^/usr/lib/chromium/chromium .*--type=renderer'); do
        grep -E '^(Seccomp|NoNewPrivs):' "/proc/$renderer/status"
        if grep -Eq '^Seccomp:[[:blank:]]+2$' "/proc/$renderer/status" &&
           grep -Eq '^NoNewPrivs:[[:blank:]]+1$' "/proc/$renderer/status" &&
           [[ $(readlink "/proc/$renderer/ns/pid") != "$(readlink "/proc/$browser/ns/pid")" ]]; then
            echo 'BROWSER_SANDBOX seccomp=2 no_new_privs=1 pid_namespace=isolated' | tee /run/panel-renderer-sandbox
            exit 0
        fi
    done
    echo 'Browser renderer sandbox observer failed' >&2
) &
