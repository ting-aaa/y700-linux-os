#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --user ]]; then
    [[ $(id -u) == 1000 && ! -e /dev/video0 && ! -e /dev/media0 && ! -e /dev/udmabuf && ! -e /dev/snd ]]
    [[ -z $(find /dev -type b -print -quit) ]]
    pipewire >"$XDG_RUNTIME_DIR/core.log" 2>&1 & core=$!
    for i in {1..80}; do [[ -S $XDG_RUNTIME_DIR/pipewire-0 ]] && break; sleep .1; done
    wireplumber --profile=video-only >"$XDG_RUNTIME_DIR/manager.log" 2>&1 & manager=$!
    cleanup() { local rc=$?; if (( rc )); then tail -n 12 "$XDG_RUNTIME_DIR"/{core,manager}.log; fi; }
    trap cleanup EXIT
    for i in {1..80}; do
        pw-dump >"$XDG_RUNTIME_DIR/graph"
        n=$(grep -c '"node.name": "y700_camera_' "$XDG_RUNTIME_DIR/graph" || :)
        ((n>=3)) && break
        sleep .25
    done
    perl -MJSON::PP -0777 -ne '
       my %g=map {$_->{id}=>$_} @{decode_json($_)};
       my @names;
       for my $item (values %g) {
         my $p=$item->{info}{props}//{}; next unless ($p->{"node.name"}//"") =~ /^y700_camera_/;
         my $f=$g{$p->{"factory.id"}}{info}{props};
         die "Unexpected source factory" unless $f->{"factory.name"} eq "spa-node-factory"
           && $p->{"factory.name"} eq "api.libcamera.source"
           && $item->{info}{state} ne "running";
         push @names,$p->{"node.name"};
       }
       die "Missing virtual source" unless join(",",sort @names) eq "y700_camera_front,y700_camera_macro,y700_camera_rear";
    ' "$XDG_RUNTIME_DIR/graph"
    so=/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
    inode=$(stat -c %i "$so")
    for pid in "$core" "$manager"; do
        LC_ALL=C /usr/bin/mawk -v p="$so" -v ino="$inode" '$6==p {seen++; if($5!=ino || NF>6) bad=1} END{exit !(seen && !bad)}' "/proc/$pid/maps"
    done
    echo 'FRESH_CAMERA_SESSION uid=1000 core_maps_current=1 manager_maps_current=1 virtual_camera_sources=3 source_factory=spa-node-factory running_sources=0 physical_devices=0'
    exit
fi
if [[ ${1:-} == --namespace ]]; then
    stage=$2
    cd "$stage"; [[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private && $(findmnt -nro FSTYPE -T .) == tmpfs ]]
    mkdir root upper work
    r=$PWD/root
    mkdir -p "$r"/{usr,opt/y700-camera/lib,etc,dev/shm,proc,sys,root,home/y700,run/user/1000,tmp,var/lib/dbus,qa}
    mount -t overlay overlay -o "lowerdir=/usr,upperdir=$PWD/upper,workdir=$PWD/work,nosuid,nodev" "$r/usr"
    for d in lib bin sbin; do ln -s "usr/$d" "$r/$d"; done
    cp /etc/{passwd,group,nsswitch.conf,ld.so.cache} "$r/etc/"
    chroot "$r" dbus-uuidgen >"$r/etc/machine-id"
    ln -s /etc/machine-id "$r/var/lib/dbus/machine-id"
    mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
    mount -t tmpfs -o ro,nodev,nosuid,noexec tmpfs "$r/proc/sys"
    mount -t tmpfs -o size=4m,mode=755,nosuid tmpfs "$r/dev"
    for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$r/dev/${pair%:*}" c 1 "${pair#*:}"; done
    ln -s /proc/self/fd "$r/dev/fd"
    install -d -m1777 "$r/dev/shm"
    chmod 1777 "$r/tmp"
    chown 1000:1000 "$r/home/y700" "$r/run/user/1000"; chmod 700 "$r/home/y700" "$r/run/user/1000"
    install -m755 libcamera{,-base}.so.0.7.2 libyuv.so.0 "$r/opt/y700-camera/lib/"
    for lib in libcamera libcamera-base; do ln -s "$lib.so.0.7.2" "$r/opt/y700-camera/lib/$lib.so.0.7"; done
    cfg="$r/usr/share/libcamera/pipeline/virtual"; mkdir -p "$cfg"
    sed -e '/^  frames:$/,+1c\  test_pattern: "lines"' -e '/^"\/fixture\/unknown/,$d' virtual-cameras.yaml > "$cfg/virtual.yaml"
    hook="$r/usr/share/wireplumber/scripts/monitors/libcamera/create-device.lua"
    [[ $(grep -Fc '  mutils:register_cam_node (parent, id, factory, properties)' "$hook") == 1 ]]
    sed -i '/^  mutils:register_cam_node /i\  properties["device.devids"] = properties["device.devids"] or "[]"' "$hook"
    so=/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
    echo "a7eab16363e28fd191944dd75e2aa6b37e0520ba2c05a47699b800ac83ae28d0  $r$so" | sha256sum --strict -c -
    cmp "$so" "$r$so"
    cp isolated-session.sh "$r/qa/check.sh"
    chroot "$r" setpriv --reuid=1000 --regid=1000 --clear-groups --no-new-privs env -i \
        HOME=/home/y700 USER=y700 PATH=/usr/bin:/bin XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/no-system-bus LD_LIBRARY_PATH=/opt/y700-camera/lib \
        LIBCAMERA_PIPELINES_MATCH_LIST=virtual dbus-run-session -- bash /qa/check.sh --user
    exit
fi
[[ $# == 3 ]] || { echo 'Usage: isolated-session.sh PINNED_USB_SSH VIRTUAL_CAMERA_LIBDIR LIBYUV_DEB' >&2; exit 2; }
ssh=$(realpath -e "$1"); libs=$(realpath -e "$2"); yuv=$(realpath -e "$3")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
stage=
cleanup() {
    local rc=$?
    if [[ $stage =~ ^/run/y700-private-media\.[[:alnum:]]{8}$ ]]; then
        bash "$ssh" "test -d '$stage' && ! grep -Fq '$stage/' /proc/self/mountinfo && rm -r --one-file-system -- '$stage'" || rc=1
    fi
    rm -r --one-file-system -- "$work"; exit "$rc"
}
trap cleanup EXIT
(cd "$libs" && sha256sum -c "$here/../tablet-desktop-ram/virtual-libs.sha256")
echo "ab0e0a3bbfb0340d7adbb47c8a622e661256f0ceb205c6a299b34f58cdcee805  $yuv" | sha256sum --strict -c -
dpkg-deb --fsys-tarfile "$yuv" | tar -xOf - --wildcards './usr/lib/aarch64-linux-gnu/libyuv.so.0.*' >"$work/libyuv.so.0"
cp "$here/isolated-session.sh" "$here/../qcam-photo/virtual-cameras.yaml" "$libs"/libcamera{,-base}.so.0.7.2 "$work/"
stage=$(bash "$ssh" '[[ $(findmnt -nro FSTYPE -T /run) == tmpfs && $(dpkg-query -W -f="\${Version}" y700-camera-pipewire) == 1.4.2-1+y700.5 ]] && mktemp -d /run/y700-private-media.XXXXXXXX' </dev/null)
[[ $stage =~ ^/run/y700-private-media\.[[:alnum:]]{8}$ ]]
tar -cf - -C "$work" . | bash "$ssh" "tar -xf - -C '$stage'"
bash "$ssh" "timeout --kill-after=5s 80s unshare --mount --propagation private --pid --fork --kill-child --ipc --net bash '$stage/isolated-session.sh' --namespace '$stage'" </dev/null
