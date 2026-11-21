#!/bin/bash
# Apply one locked layer to a copy of its sealed generic predecessor.
set -euo pipefail
if (( EUID != 0 || $# != 4 )); then
    echo 'Usage (root): update-sealed-root.sh power-desktop|blueman|platform|video-player|video-player-update|wifi-sae-update|camera-autofocus|platform-desktop-update|tablet-desktop SEALED_ROOT.ext4 LAYER_DIRECTORY_OR_TAR NEW_LINUX_DIRECTORY' >&2
    exit 2
fi
if [[ ${Y700_POWER_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_POWER_PRIVATE=1 bash "$0" "$@"
fi
layer=$1
shift
prior_args=(--sealed-blueman-y7001)
prior_inventory=
case $layer in
    power-desktop)
        parent_sha=74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd
        inventory_sha=bbb696086ce1bb4a425dbf63876f12548e7e6a6048ed89415e64cb6a793eba6a
        lock_args=(--sealed-blueman-y7001)
        ;;
    blueman)
        parent_sha=dd885eb7bc88e3fb87b0567ff7f382afbe079363910d6f0fd5b4bb41935e220a
        inventory_sha=685d01f30932a5dd7df5ccbf99c66f3908e29c5cdeda2b7abe91d727f9c09511
        lock_args=(--platform-version '0.1.0~dev12.6')
        ;;
    platform)
        parent_sha=869745fbe9e9eacb2eb981731b2b8bc6ad162756282a2244f297063a7f79a5a4
        inventory_sha=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
        prior_args=(--platform-version '0.1.0~dev12.6')
        lock_args=()
        ;;
    video-player)
        parent_sha=2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511
        prior_inventory=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
        inventory_sha=89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d
        prior_args=()
        lock_args=()
        ;;
    video-player-update)
        parent_sha=e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb
        prior_inventory=89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d
        inventory_sha=ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3
        prior_args=()
        lock_args=()
        ;;
    wifi-sae-update)
        parent_sha=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
        prior_inventory=ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3
        inventory_sha=2d180b436086b9015044bff4053c314de4b63bce4f5406baffcd1ebce79a67d8
        prior_args=()
        lock_args=()
        ;;
    camera-autofocus)
        parent_sha=0383703eac309a64e3febc286fa6c8d9fffb9c252745bb7b1647bde647a27ca0
        prior_inventory=2d180b436086b9015044bff4053c314de4b63bce4f5406baffcd1ebce79a67d8
        inventory_sha=be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d
        prior_args=()
        lock_args=()
        ;;
    platform-desktop-update)
        parent_sha=33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3
        prior_inventory=be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d
        inventory_sha=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
        prior_args=()
        lock_args=(--platform-version '0.1.0~dev12.8+gpu1.2')
        ;;
    tablet-desktop)
        parent_sha=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
        prior_inventory=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
        inventory_sha=5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098
        prior_args=(--platform-version '0.1.0~dev12.8+gpu1.2')
        lock_args=("${prior_args[@]}")
        ;;
    *) echo "Unsupported image layer: $layer" >&2; exit 2 ;;
esac
deb_layer=false
case $layer in camera-autofocus|platform-desktop-update|tablet-desktop) deb_layer=true ;; esac
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
parent=$(realpath -e "$1")
archives=$(realpath -e "$2")
out=$(realpath -m "$3")
[[ -f $parent && -d ${out%/*} && ! -e $out && ! -L $3 ]]
source "$repo/scripts/build-storage-guard.sh" root "${out%/*}"
export LC_ALL=C UV_OFFLINE=1 UV_PYTHON=${UV_PYTHON:-/usr/bin/python3}
echo "$parent_sha  $parent" | sha256sum --strict -c -
w=$(mktemp -d "${out%/*}/.y700-power-build.XXXXXXXX")
root=$w/root
cleanup() {
    if mountpoint -q "$root"; then umount -R "$root"; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir "$w"/{root,result}
raw=$w/result/root.ext4
cp --sparse=always --reflink=auto -- "$parent" "$raw"
chmod 600 "$raw"
mount -o loop,nosuid,nodev "$raw" "$root"
check=("${UV_BIN:-uv}" run --offline --no-project --python "$UV_PYTHON" python
    "$repo/scripts/verify-image-packages.py" "$root" --camera-lock "$repo/config/camera-layer.lock.json")
"${check[@]}" "${prior_args[@]}" > "$w/result/parent-inventory.log"
mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
for path in run sys dev; do mount -t tmpfs -o nosuid,mode=755 tmpfs "$root/$path"; done
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
if [[ -n $prior_inventory ]]; then
    grep -Fxq "package_digest=$prior_inventory" "$w/result/parent-inventory.log"
    lock=$repo/config/$layer.lock.json
    record=$root/var/lib/y700/build
    (cd "$record" && sha256sum -- *.lock.json) > "$w/result/inherited-SHA256SUMS"
    # Keep both compressed inputs and every temporary package outside the ext4.
    stage=$root/run/media-build
    install -d -m755 "$stage" "$root/dev/pts"
    mount -t devpts -o newinstance,ptmxmode=0666 devpts "$root/dev/pts"
    ln -s pts/ptmx "$root/dev/ptmx"
    mknod -m666 "$root/dev/tty" c 5 0
    if ! "$deb_layer"; then
        cp -- "$archives" "$stage/layer.tar"
        [[ $(stat -c %s "$stage/layer.tar") == "$(jq -er .size "$lock")" ]]
        echo "$(jq -er .sha256 "$lock")  $stage/layer.tar" | sha256sum --strict -c -
        tar -xf "$stage/layer.tar" -C "$stage"
    fi
    if [[ $layer == video-player ]]; then
        tar -xzOf "$stage/y700-parole-iris/debian-player.tar.gz" y700-video-player/debian.lock.json > "$stage/debian.lock.json"
        echo "$(jq -er .debian_lock_sha256 "$lock")  $stage/debian.lock.json" | sha256sum --strict -c -
        cmp "$repo/tests/video-player/debian.lock.json" "$stage/debian.lock.json"
        install_command=(/run/media-build/y700-parole-iris/install.sh --install)
        verify_command=(/run/media-build/y700-parole-iris/install.sh --verify)
    elif [[ $layer == video-player-update ]]; then
        candidate_dir=$stage/y700-player-update/candidate
        deb=$(jq -er '.packages[0] | "\(.package)_\(.version)_\(.architecture).deb"' "$lock")
        echo "$(jq -er '.packages[0].sha256' "$lock")  $candidate_dir/$deb" | sha256sum --strict -c -
        cmp "$stage/y700-player-update/stock/libgstvideo4linux2.so" "$root/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so"
        install_command=(bash /run/media-build/y700-player-update/install.sh install)
        verify_command=(bash /run/media-build/y700-player-update/install.sh verify)
    elif "$deb_layer"; then
        [[ -d $archives && ! -e $record/$layer.lock.json ]]
        [[ $(jq -er .parent_root_sha256 "$lock") == "$parent_sha" ]]
        if [[ $layer == platform-desktop-update ]]; then
            (cd "$repo" && jq -r '.recipes | to_entries[] | "\(.value)  \(.key)"' "$lock" | sha256sum --strict -c -) > "$w/result/recipe-check.log"
            [[ $(jq -er '.packages | length' "$lock") == 1 ]]
        fi
        install_command=(dpkg --install)
        verify_command=(dpkg --verify)
        while IFS=$'\t' read -r name version arch size digest; do
            deb=${name}_${version}_${arch}.deb
            cp -- "$archives/$deb" "$stage/$deb"
            [[ $(stat -c %s "$stage/$deb") == "$size" ]]
            echo "$digest  $stage/$deb" | sha256sum --strict -c -
            [[ $(dpkg-deb -W --showformat='${Package}_${Version}_${Architecture}.deb' "$stage/$deb") == "$deb" ]]
            install_command+=("/run/media-build/$deb")
            verify_command+=("$name")
        done < <(jq -r '.packages[] | [.package,.version,.architecture,.size,.sha256] | @tsv' "$lock")
        if [[ $layer == camera-autofocus ]]; then
            [[ ${#install_command[@]} == 5 ]]
        elif [[ $layer == tablet-desktop ]]; then
            [[ ${#install_command[@]} == 6 && ! -e $root/etc/xdg/autostart/ibus.desktop && ! -L $root/etc/xdg/autostart/ibus.desktop ]]
        else
            [[ ${#install_command[@]} == 3 && ${verify_command[2]} == y700-platform ]]
            dpkg-deb -x "$stage/$deb" "$stage/payload"
            (cd "$stage/payload" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$w/result/platform-payload.sha256"
        fi
    else
        cmp "$repo/config/wifi-sae-update.sha256" "$stage/update/SHA256SUMS"
        (cd "$stage/update" && sha256sum --strict -c SHA256SUMS)
        install_command=(dpkg --install)
        for deb in "$stage"/update/candidate/*.deb; do
            package=$(dpkg-deb -f "$deb" Package)
            version=$(dpkg-deb -f "$deb" Version)
            arch=$(dpkg-deb -f "$deb" Architecture)
            digest=$(sha256sum "$deb" | cut -d' ' -f1)
            jq -e --arg pkg "$package" --arg ver "$version" --arg arch "$arch" --arg sha "$digest" \
                '.packages | any(.package==$pkg and .version==$ver and .architecture==$arch and .sha256==$sha)' "$lock" >/dev/null
            install_command+=("${deb#"$root"}")
        done
        verify_command=(dpkg --verify network-manager wpasupplicant)
    fi
    [[ ! -e $root/usr/sbin/policy-rc.d && ! -L $root/usr/sbin/policy-rc.d ]]
    printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
    chmod 755 "$root/usr/sbin/policy-rc.d"
    run=(chroot "$root" env TMPDIR=/run SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive)
    # Debian maintainer scripts expect the normal system umask.
    (umask 022; "${run[@]}" "${install_command[@]}") | tee "$w/result/install.log"
    if [[ $layer == wifi-sae-update ]] || "$deb_layer"; then
        verify_log=wifi-package-verify.log
        if [[ $layer == tablet-desktop ]]; then verify_log=desktop-apps-verify.log; fi
        if [[ $layer == camera-autofocus ]]; then verify_log=camera-package-verify.log; fi
        if [[ $layer == platform-desktop-update ]]; then
            verify_log=platform-package-verify.log
            (cd "$root" && sha256sum --strict -c "$w/result/platform-payload.sha256") > "$w/result/payload-check.log"
        fi
        "${run[@]}" "${verify_command[@]}" > "$w/result/$verify_log"
        [[ ! -s $w/result/$verify_log ]]
    else
        "${run[@]}" "${verify_command[@]}"
    fi
    "${run[@]}" apt-get check
    [[ -z $("${run[@]}" dpkg --audit) ]]
    rm -- "$root/usr/sbin/policy-rc.d"
    install -m644 "$lock" "$record/$layer.lock.json"
    if [[ $layer == camera-autofocus ]]; then
        [[ $(readlink "$root/etc/os-release") == ../usr/lib/os-release && ! -e $root/etc/os-release.debian ]]
        [[ -z $(chroot "$root" dpkg-divert --list /etc/os-release) ]]
        chroot "$root" dpkg-divert --local --rename --add --divert /etc/os-release.debian /etc/os-release
        install -m644 "$root/usr/lib/os-release" "$root/etc/os-release"
        printf '%s\n' 'IMAGE_ID=y700-prc-debian' 'IMAGE_VERSION=dev12.11' \
            'VARIANT="Lenovo Legion Y700 (2023) Xfce"' 'VARIANT_ID=y700_xfce' >> "$root/etc/os-release"
    elif [[ $layer == tablet-desktop ]]; then
        grep -Fxq IMAGE_VERSION=dev12.12 "$root/etc/os-release"
        sed -i 's/^IMAGE_VERSION=dev12\.12$/IMAGE_VERSION=dev12.13/' "$root/etc/os-release"
        [[ $(blkid -p -s UUID -o value "$raw") == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
    elif [[ $layer == platform-desktop-update ]]; then
        grep -Fxq IMAGE_VERSION=dev12.11 "$root/etc/os-release"
        sed -i 's/^IMAGE_VERSION=dev12\.11$/IMAGE_VERSION=dev12.12/' "$root/etc/os-release"
        [[ $(blkid -p -s UUID -o value "$raw") == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
    fi
    if "$deb_layer"; then
        [[ $(chroot "$root" dpkg-divert --truename /etc/os-release) == /etc/os-release.debian ]]
        [[ $(readlink "$root/etc/systemd/system/graphical.target.wants/y700-firstboot.service") == /etc/systemd/system/y700-firstboot.service ]]
        grep -Fxq 'ConditionPathExists=!/etc/y700/user-configured' "$root/etc/systemd/system/y700-firstboot.service"
        grep -Fxq 'ExecStart=/usr/libexec/y700-firstboot-drm/firstboot' \
            "$root/usr/lib/systemd/system/y700-firstboot.service.d/60-drm-keyboard.conf"
        [[ -x $root/usr/libexec/y700-firstboot-drm/firstboot && -f $root/etc/y700/base-configured ]]
        [[ $(readlink "$root/etc/systemd/system/display-manager.service") == /lib/systemd/system/lightdm.service ]]
        [[ $(readlink "$root/etc/systemd/system/default.target") == /usr/lib/systemd/system/graphical.target ]]
        grep -Fxq 'y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f' "$root/etc/y700/image-id"
        echo 'Firstboot DRM entry enabled, enrollment marker absent, LightDM graphical target selected.' > "$w/result/firstboot-check.log"
    fi
    if [[ $layer == video-player ]]; then
        install -m644 "$stage/debian.lock.json" "$record/video-player-debian.lock.json"
    fi
    chroot "$root" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$record/packages.tsv"
    if [[ $layer == video-player-update ]]; then
        [[ ! -e $record/.y700-player-update-pending && ! -e $root/usr/local/lib/y700-parole/gstreamer-1.0/.y700-player-update-next ]]
    fi
    (cd "$record" && sha256sum --strict -c "$w/result/inherited-SHA256SUMS")
    if [[ $layer == video-player-update ]]; then
        # The previous, already distributed updater requires its exact active
        # dev12.9 receipt. Retain those bytes as history and advance the active one.
        [[ ! -e $record/video-player-dev12.9.lock.json && ! -L $record/video-player-dev12.9.lock.json ]]
        mv -T "$record/video-player.lock.json" "$record/video-player-dev12.9.lock.json"
        install -m644 "$lock" "$record/video-player.lock.json"
        cmp "$repo/config/video-player.lock.json" "$record/video-player-dev12.9.lock.json"
        if "${run[@]}" bash /run/media-build/y700-player-update/install.sh check > "$w/result/updater-edition-check.log" 2>&1; then
            echo 'The distributed dev12.9 updater unexpectedly accepted dev12.10' >&2
            exit 1
        fi
        grep -Fq '/var/lib/y700/build/video-player.lock.json: FAILED' "$w/result/updater-edition-check.log"
    fi
else
    touch "$root/.y700-disposable-build-root"
    bash "$repo/scripts/add-board-layer.sh" "${lock_args[@]}" "$layer" "$root" "$archives" | tee "$w/result/install.log"
    rm -- "$root/.y700-disposable-build-root"
fi
chmod 644 "$root/var/lib/y700/build/packages.tsv"
if [[ $layer == tablet-desktop ]]; then
    cp "$record/packages.tsv" "$w/result/packages.tsv"
    cp "$record/$layer.lock.json" "$w/result/$layer.lock.json"
fi
"${check[@]}" "${lock_args[@]}" | tee "$w/result/inventory.log"
grep -Fxq "package_digest=$inventory_sha" "$w/result/inventory.log"
if [[ $layer == blueman || $layer == platform ]]; then
    package=blueman
    if [[ $layer == platform ]]; then package=y700-platform; fi
    [[ -z $(chroot "$root" dpkg -V "$package") ]]
    cmp "$repo/config/$layer.lock.json" "$root/var/lib/y700/build/$layer.lock.json"
fi
for path in "$root"/{etc/NetworkManager/system-connections,var/lib/bluetooth,var/lib/y700-ssc}; do
    [[ ! -d $path || -z $(find "$path" -mindepth 1 -print -quit) ]]
done
[[ -f $root/etc/machine-id && ! -s $root/etc/machine-id ]]
[[ $(chroot "$root" passwd -S y700 | cut -d' ' -f2) == L ]]
for path in "$root"/{etc/y700/maintenance*,etc/y700/bluetooth-address,etc/y700/user-configured,etc/ssh/ssh_host_*,home/y700/.ssh,root/.ssh,var/lib/y700-ssc/registry,var/lib/y700/ssh,var/lib/systemd/random-seed,var/lib/systemd/credential.secret}; do
    [[ ! -e $path && ! -L $path ]]
done
if [[ $layer == video-player-update || $layer == wifi-sae-update ]] || "$deb_layer"; then
    # Inspect the on-disk /run only after removing the installer staging tmpfs.
    umount "$root/run"
    [[ ! -L $root/etc/machine-id && $(readlink "$root/var/lib/dbus/machine-id") == /etc/machine-id ]]
    for path in "$root"/{run/y700-speaker-calibration,run/media-build,var/lib/alsa/asound.state,var/lib/NetworkManager/secret_key,persist,mnt/vendor/persist}; do
        [[ ! -e $path && ! -L $path ]]
    done
    echo 'Generic identity verified: empty machine-id, locked account, no pairing, owner network, SSH keys, unit calibration or installer staging.' > "$w/result/identity-check.log"
fi
umount -R "$root"
e2fsck -fn "$raw" >"$w/result/filesystem-check.log"
chmod 400 "$raw"
(cd "$w/result" && sha256sum root.ext4 >SHA256SUMS)
echo "$parent_sha  $parent" | sha256sum --strict -c -
mv -T --no-clobber "$w/result" "$out"
test ! -e "$w/result"
cat "$out/SHA256SUMS"
