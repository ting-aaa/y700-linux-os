#!/bin/bash
set -euo pipefail
export LC_ALL=C
ulimit -c 0
cd "$1"
stage=$PWD
helper=$(realpath -e "$2")
source ./profiles.sh
ram_profile "$3"
[[ ($release == dev12.8 || $release == dev12.9 || $release == dev12.10) && $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
for ns in mnt pid net ipc; do [[ $(readlink "/proc/self/ns/$ns") != "$(cat "host-$ns")" ]]; done
mapfile -t nodes < <(grep -lFx qcom-iris-decoder /sys/class/video4linux/video*/name)
[[ ${#nodes[@]} == 1 && $(cat /sys/bus/platform/devices/aa00000.video-codec/power/runtime_status) == suspended ]]
dev=$(basename "$(dirname "${nodes[0]}")")
[[ $dev =~ ^video[0-9]+$ ]]
chip=/sys/bus/platform/devices/aa00000.video-codec
[[ $(readlink -f "/sys/class/video4linux/$dev/device") == "$(realpath "$chip")" ]]
[[ $(sha256sum /sys/kernel/notes | cut -d' ' -f1) == 2e6b047aba528bfdea5549b9aae9af362a9af055bb630a650bcdd7c654ec9066 ]]
runuser -u y700 -- test -w "/dev/$dev"
mkdir squash lower changes root
mount -t squashfs -o ro,loop,nosuid,nodev,noexec carrier squash
echo "$root_sha  squash/root.ext4" | sha256sum --strict -c
mount -t ext4 -o loop,ro,noload,nosuid,nodev squash/root.ext4 lower
mount -t tmpfs -o size=1g,mode=755,nosuid,nodev tmpfs changes
mkdir changes/{work,upper}
mount -t overlay -o "lowerdir=$stage/lower,upperdir=$stage/changes/upper,workdir=$stage/changes/work,nosuid,nodev" overlay root
mount -t tmpfs -o size=128m,mode=1777,nosuid,nodev tmpfs root/tmp
mount -t tmpfs -o size=256m,mode=755,nosuid,nodev tmpfs root/run
mount -t tmpfs -o size=4m,mode=755,nosuid tmpfs root/dev
mount -t proc -o nosuid,nodev,noexec proc root/proc
mount -t tmpfs -o ro,nosuid,nodev,noexec tmpfs root/proc/sys
mount -t sysfs -o ro,nosuid,nodev,noexec sysfs root/sys
for name in null zero urandom random; do touch "root/dev/$name"; mount --bind "/dev/$name" "root/dev/$name"; done
ln -s /proc/self/fd root/dev/fd
install -d -m1777 root/dev/shm root/tmp/.X11-unix
install -d -m755 root/qa/{bin,clips} root/home/y700
install -d -m700 -o 1000 -g 1000 root/run/user/1000
install -m755 "$helper/bin/Xvfb" "$(command -v uv)" root/qa/bin/
install -m644 parole-desktop.sh check-x11.py root/qa/
if [[ -f parole-transport.py ]]; then install -m644 parole-transport.py root/qa/; fi
if [[ -f transport-codec ]]; then install -m644 transport-codec root/qa/; fi
if [[ -f save-player-trace ]]; then touch root/qa/save-player-trace; fi
install -m644 h264.mp4 hevc.mp4 vp9.webm root/qa/clips/
chroot root dbus-uuidgen >root/etc/machine-id
player_env=()
if [[ $release == dev12.9 || $release == dev12.10 ]]; then
    [[ ! -e player.tgz ]]
    chroot root dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort > inventory
    [[ $(wc -l <inventory) == "$package_count" ]]
    printf '%s  inventory\n' "$package_sha" | sha256sum -c --strict
    chroot root dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' |
        cmp - lower/var/lib/y700/build/packages.tsv
    echo "PLAYER_PREINSTALLED edition=$release packages=$package_count package_sha=$package_sha"
    if [[ $release == dev12.10 ]]; then
        [[ ! -e plugin.so && ! -e upgrade.tgz ]]
        (cd lower && sha256sum --strict -c <<'HASHES'
76cb6ec197596e29ee5a720160b0b1683c38864b80f10dec6759a8fa5a49f2cb  usr/bin/parole
a64bdb5bf9e4454f371638cf17c2564c3cbe3a3bc379ba5151de3c689f4a69f0  usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so
844986bb49db504a7e5611af2496b4f80f85af74fdc6ce068f0d259fa9c1c93f  usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so
HASHES
        )
        touch root/qa/single-seek
    elif [[ -f plugin.so ]]; then
        target=/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so
        echo "7c3e57f206c81fa0af09a3cf34d9836a686527212c7738dc4657d6c315ec9962  root$target" | sha256sum -c --status
        install -m644 plugin.so "root$target"
        echo "PLAYER_TRIAL_PLUGIN storage=tmpfs sha256=$(sha256sum "root$target" | cut -d' ' -f1)"
    fi
else
    printf '#!/bin/sh\nexit 101\n' > root/usr/sbin/policy-rc.d
    chmod 755 root/usr/sbin/policy-rc.d
    tar --no-same-owner -xf player.tgz -C root/run
    installer=/run/y700-parole-iris/install.sh
    if [[ -f plugin.so ]]; then
        installer=/run/y700-video-player/install.sh
        install -D -m644 plugin.so root/qa/plugin/libgstvideo4linux2.so
        player_env=(GST_PLUGIN_PATH_1_0=/qa/plugin)
    fi
    if ! chroot root bash "$installer" --install >install.log 2>&1; then tail -25 install.log; exit 1; fi
    grep -E 'Preflight passed|Installed 1240 packages' install.log
fi
baseline_version=4.18.2-1
if [[ $release == dev12.10 ]]; then baseline_version+=+y7002; fi
[[ $(chroot root dpkg-query -W -f='${Version}' parole) == "$baseline_version" ]]
if [[ -f upgrade.tgz ]]; then
    [[ $release == dev12.9 && ! -e plugin.so ]]
    tar --no-same-owner -xzf upgrade.tgz -C root/run
    installer=/run/y700-player-update/install.sh
    if ! chroot root bash "$installer" install >install-upgrade.log 2>&1; then tail -25 install-upgrade.log; exit 1; fi
    chroot root bash "$installer" verify
    version=$(chroot root dpkg-query -W -f='${db:Status-Status} ${Version}' parole)
    case "$version" in
        'installed 4.18.2-1+y7001') ;;
        'installed 4.18.2-1+y7002') touch root/qa/single-seek ;;
        *) exit 1 ;;
    esac
    echo "PLAYER_TRIAL_UPGRADE storage=tmpfs sha256=$(sha256sum upgrade.tgz | cut -d' ' -f1)"
fi
touch "root/dev/$dev"
mount --bind "/dev/$dev" "root/dev/$dev"
devnum=$(cat "/sys/class/video4linux/$dev/dev")
[[ $devnum =~ ^[0-9]+:[0-9]+$ ]]
install -D -m644 "/run/udev/data/c$devnum" "root/run/udev/data/c$devnum"
cursor=$(journalctl -k -b -n 0 --show-cursor --no-pager | sed -n 's/^-- cursor: //p')
[[ -n $cursor ]]
player_rc=0
chroot root setpriv --reuid=y700 --regid=y700 --init-groups --no-new-privs \
    env -i PATH=/qa/bin:/usr/local/bin:/usr/bin:/bin HOME=/home/y700 USER=y700 LOGNAME=y700 \
    XDG_RUNTIME_DIR=/run/user/1000 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 GDK_SCALE=2 GDK_BACKEND=x11 \
    "${player_env[@]}" LC_ALL=C.UTF-8 DISPLAY=:73 \
    dbus-run-session -- bash /qa/parole-desktop.sh "$dev" || player_rc=$?
runtime=root/run/user/1000
if [[ -f save-player-trace && -s $runtime/player-open.log ]]; then
    mkdir -m700 player-trace
    for pid in $(sed -nE 's/^(PLAYER_OPEN|PAROLE_TRANSPORT_START) .* pid=([0-9]+)( .*)?$/\2/p' "$runtime/player-open.log" | sort -u); do
        log="$runtime/media-$pid.log"
        if [[ -f $log && ! -L $log && $(stat -c %s "$log") -le 16777216 ]]; then
            cp -- "$log" player-trace/
        fi
    done
    cp -- "$runtime/player-open.log" player-trace/
    tar -czf player-trace.tar.gz player-trace
fi
for _ in {1..12}; do [[ $(cat /sys/bus/platform/devices/aa00000.video-codec/power/runtime_status) != suspended ]] || break; sleep .5; done
[[ $(cat /sys/bus/platform/devices/aa00000.video-codec/power/runtime_status) == suspended ]]
journalctl -k -b --after-cursor="$cursor" -o cat --no-pager -q >kernel.log
if grep -Ei '(iris|vpu|video-codec|iommu|arm-smmu).*(fatal|retained|fault|watchdog|timeout|timed out|failed.*ownership)|Unhandled context fault' kernel.log; then
    exit 1
fi
[[ $player_rc == 0 ]] || exit "$player_rc"
if [[ (-f upgrade.tgz || $release == dev12.10) && -f parole-transport.py ]]; then
    expected=3
    if [[ -f transport-codec ]]; then expected=1; fi
    awk -v expected="$expected" '
        /^PAROLE_TRANSPORT_CONTROLS / {
            if (!sub(/^slider_px=/, "", $4) || !sub(/^play_pause_px=/, "", $5)) exit 1
            if (split($4, slider, "x") != 2 || split($5, button, "x") != 2) exit 1
            if (slider[2]+0 < 96 || button[1]+0 < 96 || button[2]+0 < 96) exit 1
            count++
        }
        END { if (count != expected) exit 1 }
    ' "$runtime/player-open.log"
    echo "PAROLE_TOUCH_PASS tested=$expected min_logical_pixels=48 gtk_scale=2"
fi
echo 'IRIS_PAROLE_PASS packages=1240 storage=tmpfs decoder=runtime_suspended'
