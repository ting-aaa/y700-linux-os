#!/bin/bash
# Test the stock ARM64 Xfce dialog on a read-only dev12.11 root and two virtual modes.
set -euo pipefail
if [[ ${1:-} == --user ]]; then
    export PATH=/usr/bin:/bin LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=en
    export XDG_CURRENT_DESKTOP=XFCE GDK_SCALE=2 GDK_BACKEND=x11 NO_AT_BRIDGE=0
    export GTK_USE_PORTAL=0 GIO_USE_VFS=local
    cd /opt/y700-topology
    xrandr --output DUMMY0 --mode portrait120 --primary --pos 0x0 --fb 1600x2560
    dbus-run-session -- bash -ec '
        dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR GDK_SCALE NO_AT_BRIDGE
        xfwm4 --compositor=off >"$XDG_RUNTIME_DIR/wm.log" 2>&1 &
        xfsettingsd --replace --no-daemon >"$XDG_RUNTIME_DIR/settings.log" 2>&1 &
        for i in {1..80}; do xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id" && break; sleep .3; done
        exec ./uv run --offline --no-project --python /usr/bin/python3 python -B xfce-dialog.py'
    echo TOPOLOGY_PASS
    exit
fi
[[ $# == 5 ]] || { echo 'Usage: xfce-dialog.sh SEALED_EXT4 DUAL_REFRESH_KERNEL ARM64_BUSYBOX DUMMY_ARM64_DEB ARM64_UV' >&2; exit 2; }
here=$(realpath -e "$(dirname "$0")")
common=$here/../display-touch-topology
root=$(realpath -e "$1")
printf '%s  %s\n' 33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3 "$root" \
    0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$2" | sha256sum --strict -c -
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-xfce-refresh.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
mkdir "$work"/{runner,payload}
ln -s "$here/../touch-gestures" "$work/touch-gestures"
cp "$common/run-qemu.sh" "$work/runner/"
cp "$here/xfce-dialog.py" "$here/xfce-dialog.sh" "$work/payload/"
install -m755 "$5" "$work/payload/uv"
# The dummy Xorg advertises the panel's exact two timings on an emulated output.
sed -e 's/DacSpeed 400/DacSpeed 800/' -e 's/HorizSync 5-200/HorizSync 5-500/' \
    -e '/Modeline "portrait" /c\    Modeline "portrait120" 691.524 1600 1874 1914 2022 2560 2590 2594 2850\n    Modeline "portrait60" 691.524 1600 1874 1914 2022 2560 5440 5444 5700' \
    -e 's/Modes "portrait"/Modes "portrait120" "portrait60"/' "$common/guest.sh" > "$work/payload/server.sh"
cat >"$work/runner/guest.sh" <<'GUEST'
#!/bin/bash
set -eu
cd /opt/y700-topology
tar xf old-watcher
dbus-uuidgen > /etc/machine-id
exec bash server.sh
GUEST
printf '#!/bin/bash\nexec bash ./xfce-dialog.sh --user\n' >"$work/runner/cases.sh"
tar -C "$work/payload" --mtime=@0 --mode='u+rwX,go+rX,go-w' -cf "$work/test.tar" xfce-dialog.py xfce-dialog.sh server.sh uv
"${QEMU_IMG:-qemu-img}" create -q -f qcow2 -F raw -b "$root" "$work/root.qcow2"
bash "$work/runner/run-qemu.sh" "$work/root.qcow2" "$2" "$3" "$4" "$work/test.tar"
