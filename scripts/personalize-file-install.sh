#!/bin/bash
# Migrate one TB320FC_PRC installation into its independently staged dev12.10 root.
set -Eeuo pipefail
set +x
umask 077
export LC_ALL=C
trap 'echo "Installation preparation stopped at line $LINENO" >&2' ERR
upgrade=false
if [[ $# == 2 && $1 == --dev12.11 ]]; then
    upgrade=true
    controller=$(realpath -e -- "$2")
    [[ -f $controller && ! -L $2 && $(stat -c %u "$controller") == 0 ]]
    [[ -z $(find "$controller" -perm /022 -print -quit) ]]
elif [[ $# != 0 ]]; then
    echo 'Usage: personalize-file-install.sh [--dev12.11 ROOT_OWNED_TRIAL_CONTROLLER]' >&2; exit 2
fi
[[ $EUID == 0 ]]
if [[ ${Y700_INSTALL_NS:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_INSTALL_NS=1 bash "$0" "$@"
fi
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
generic_uuid=171a4adb-916b-4763-9e6f-722b4a99988f
installed_uuid=c0e447e4-82db-59ee-91d6-0e1ec9d5f45e
installed_esp=31EC-3084
private_file() {
    [[ -f $1 && ! -L $1 && $(stat -c '%u:%g:%a:%h' "$1") == 0:0:600:1 ]]
}
private_dir() {
    [[ -d $1 && $(realpath -e -- "$1") == "$1" && $(stat -c '%u:%g:%a' "$1") == 0:0:700 ]]
}
active_loop() {
    local dev
    dev=$(findmnt -nro SOURCE -M "$1")
    private_file "$2"
    [[ $dev =~ ^/dev/loop[0-9]+$ && $(losetup --raw -nO OFFSET "$dev") == 0 &&
       $(losetup --raw -nO BACK-INO "$dev") == "$(stat -c %i "$2")" &&
       $(losetup --raw -nO BACK-MAJ:MIN "$dev") == "$(findmnt -nro MAJ:MIN -M "$backing")" ]]
}
if $upgrade; then
    backing=/run/initramfs/backing
    store=$backing/var/lib/y700-trial
    seed=$store/.dev12.11-input
    dir=$store/.dev12.11-preparing
    target=$store/dev12.11
    sys_sha=33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3
    fat_sha=92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36
    af_sha=411490734a965ca1405ca33e3b9a1fcb79a1fbad196d947cf3736cb66b1b41b1
    [[ $(findmnt -nro UUID -M "$backing") == ef306764-2315-4235-8796-69e2c9b61946 &&
       $(cat "$backing/etc/y700/image-id") == asphalt-prc-debian13-xfce-7.3.4-v1 &&
       $(findmnt -nro UUID -M /) == "$generic_uuid" && $(findmnt -nro UUID -M /boot) == 171A-4ADB &&
       $(cat /etc/y700/image-id) == "y700-prc-$generic_uuid" ]]
    grep -Fqw y700.release=dev12.10 /proc/cmdline
    grep -Fqw y700.media=file /proc/cmdline
    private_dir "$store"; private_dir "$seed"; private_dir "$store/dev12.10"
    [[ $(findmnt -nro TARGET -T "$seed") == "$backing" ]]
    active_loop / "$store/dev12.10/root.ext4"
    active_loop /boot "$store/dev12.10/linux-boot.fat"
    exec {lock}<"$store"; flock -n "$lock"
    [[ ! -e $target && ! -L $target ]] || { echo 'Published dev12.11 exists; retained.' >&2; exit 1; }
    private_file "$seed/root.ext4"; private_file "$seed/linux-boot.fat"
    [[ -z $(losetup -j "$seed/root.ext4") && -z $(losetup -j "$seed/linux-boot.fat") ]]
    stamps=$(printf '%s  %s\n' "$sys_sha" root.ext4 "$fat_sha" linux-boot.fat)
    (cd "$seed" && sha256sum --strict -c - <<<"$stamps")
    if [[ ! -e $dir && ! -L $dir ]]; then
        setup=$(mktemp -d "$store/.prepare-dev12.11.XXXXXXXX")
        printf '%s\n' "$stamps" > "$setup/sources.sha256"
        mv -nT "$setup" "$dir"; [[ ! -e $setup ]]
    fi
    private_dir "$dir"; private_file "$dir/sources.sha256"
    [[ $(findmnt -nro TARGET -T "$dir") == "$backing" && $(cat "$dir/sources.sha256") == "$stamps" ]]
    shopt -s dotglob nullglob
    for file in "$dir"/*; do
        case ${file##*/} in root.ext4|linux-boot.fat|sources.sha256|migration.log|installed.ok) ;; *) exit 1 ;; esac
        private_file "$file"
        [[ $(findmnt -nro TARGET -T "$file") == "$backing" && -z $(losetup -j "$file") ]]
    done
    shopt -u dotglob nullglob
    image=$dir/root.ext4
    fat=$dir/linux-boot.fat
    # Only unpublished, validated scratch can be recreated on retry.
    cp --sparse=always --reflink=auto -- "$seed/root.ext4" "$image"
    cp --sparse=always --reflink=auto -- "$seed/linux-boot.fat" "$fat"
    (cd "$dir" && sha256sum --strict -c sources.sha256)
    e2fsck -fn "$image" >/dev/null
    fsck.fat -n "$fat" >/dev/null
    tune2fs -U "$installed_uuid" "$image" >/dev/null
    fatlabel -i "$fat" 31ec3084
    [[ $(blkid -p -s UUID -o value "$image") == "$installed_uuid" &&
       $(blkid -p -s UUID -o value "$fat") == "$installed_esp" ]]
    fallocate -l 1073741824 "$fat"
    fsck.fat -n "$fat" >/dev/null
else
[[ $(findmnt -nro UUID -M /) == ef306764-2315-4235-8796-69e2c9b61946 ]]
[[ $(findmnt -nro UUID -M /boot) == B6D4-FA81 && $(cat /etc/y700/image-id) == asphalt-prc-debian13-xfce-7.3.4-v1 ]]
dir=/var/lib/y700-trial/dev12.10
image=$dir/root.ext4
[[ $(realpath -e "$image") == "$image" && $(findmnt -nro TARGET -T "$image") == / ]]
[[ $(stat -c '%u:%g:%a:%h' "$image") == 0:0:600:1 && $(stat -c '%u:%g:%a' "$dir") == 0:0:700 ]]
exec {lock}<"$dir"
flock -n "$lock"
[[ -z $(losetup -j "$image") && ! -e $dir/installed.ok && ! -L $dir/installed.ok ]]
[[ $(findmnt -nro FSTYPE -T /run) == tmpfs && $(df -B1 --output=avail /run | tail -1) -gt $(du -s -B1 /home/y700 | cut -f1)+134217728 ]]
[[ $(id -u y700):$(id -g y700) == 1000:1000 && $(passwd -S y700 | cut -d' ' -f2) == P ]]
[[ -f /etc/y700/user-configured ]]
original=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
if [[ ! -e $dir/resize-source.sha256 ]]; then
    printf '%s  %s\n' "$original" "$image" | sha256sum --strict -c -
    printf '%s\n' "$original" > "$dir/resize-source.sha256"
fi
[[ $(cat "$dir/resize-source.sha256") == "$original" ]]
fi
if $upgrade; then
    [[ $(findmnt -nro FSTYPE -T /run) == tmpfs && $(df -B1 --output=avail /run | tail -1) -gt $(du -s -B1 /home/y700 | cut -f1)+134217728 ]]
    [[ $(id -u y700):$(id -g y700) == 1000:1000 && $(passwd -S y700 | cut -d' ' -f2) == P && -f /etc/y700/user-configured ]]
fi
size=$(stat -c %s "$image")
[[ $size == 6442450944 || $size == 34359738368 ]]
if ! $upgrade; then [[ $(blkid -p -o value -s UUID "$image") == "$generic_uuid" ]]; fi
e2fsck -fn "$image" >/dev/null
fallocate -l 34359738368 "$image"
fsck_rc=0
e2fsck -fp "$image" >/dev/null || fsck_rc=$?
[[ $fsck_rc == 0 || $fsck_rc == 1 ]]
resize2fs "$image" >/dev/null
e2fsck -fn "$image" >/dev/null
tmp=$(mktemp -d /run/y700-install-personal.XXXXXXXX)
new=$tmp/root
mkdir "$new"
cleanup() {
    if mountpoint -q "$new"; then umount -R "$new"; fi
    if ! mountpoint -q "$new"; then rm -r --one-file-system -- "$tmp"; fi
}
trap cleanup EXIT
mount -o loop,rw "$image" "$new"
[[ $(cat "$new/etc/y700/image-id") == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
if $upgrade; then
    echo "$af_sha  $new/var/lib/y700/build/camera-autofocus.lock.json" | sha256sum --strict -c -
    [[ $(findmnt -nro UUID -M "$new") == "$installed_uuid" ]]
    grep -Fxq IMAGE_VERSION=dev12.11 "$new/etc/os-release"
    grep -Fxq "UUID=$generic_uuid / ext4 defaults 0 1" "$new/etc/fstab"
    grep -Fxq 'UUID=171A-4ADB /boot vfat umask=0077 0 2' "$new/etc/fstab"
    sed -i -e "s/^UUID=$generic_uuid /UUID=$installed_uuid /" -e "s/^UUID=171A-4ADB /UUID=$installed_esp /" "$new/etc/fstab"
    printf 'y700-prc-%s\n' "$installed_uuid" > "$new/etc/y700/image-id"
    chmod 644 "$new/etc/fstab" "$new/etc/y700/image-id"
fi
[[ $(sha256sum "$new/var/lib/y700/build/video-player.lock.json" | cut -d' ' -f1) == 39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb ]]
[[ $(chroot "$new" id -u y700):$(chroot "$new" id -g y700) == 1000:1000 ]]
for path in etc etc/ssh home root var/lib; do [[ $(realpath -e "$new/$path") == "$new/$path" ]]; done
mount -t tmpfs -o nosuid tmpfs "$new/dev"
for node in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$new/dev/${node%:*}" c 1 "${node#*:}"; done
mount -t tmpfs -o nosuid,nodev tmpfs "$new/run"
mount -t proc -o nosuid,nodev,noexec proc "$new/proc"
install -d -m755 "$new/run/sshd"

# Archive on the tablet so user files and device credentials stay on this device.
tar_flags=(--numeric-owner --acls --xattrs --xattrs-include='*')
if ! $upgrade; then
    tar --one-file-system "${tar_flags[@]}" -cf "$tmp/home.tar" -C /home y700
    tar "${tar_flags[@]}" -xpf "$tmp/home.tar" -C "$new/home"
    tar "${tar_flags[@]}" -df "$tmp/home.tar" -C "$new/home" >"$tmp/home-diff"
    [[ ! -s $tmp/home-diff ]]
fi
snapshot_home() {
    tar --one-file-system "${tar_flags[@]}" -cf "$tmp/home.tar" -C /home y700 || return 1
    # Start empty so both removals and additions are reflected on retries.
    [[ -d $new/home/y700 && $(realpath -e "$new/home/y700") == "$new/home/y700" &&
       -z $(findmnt -n -M "$new/home/y700") ]] || return 1
    rm -r --one-file-system -- "$new/home/y700" || return 1
    tar "${tar_flags[@]}" -xpf "$tmp/home.tar" -C "$new/home" || return 1
    tar "${tar_flags[@]}" -df "$tmp/home.tar" -C "$new/home" || return 1
    tar "${tar_flags[@]}" -df "$tmp/home.tar" -C /home || return 1
    # GNU tar ignores Unix sockets. Check the complete persistent path set with NUL delimiters.
    find /home/y700 -xdev ! -type s -printf '%P\0' | sort -z >"$tmp/live-home.names" || return 1
    find "$new/home/y700" -xdev ! -type s -printf '%P\0' | sort -z >"$tmp/copied-home.names" || return 1
    cmp -s "$tmp/live-home.names" "$tmp/copied-home.names"
}
copy_path() {
    local path=$1
    [[ -e /$path && ! -L /$path && $(realpath -e "/$path") == "/$path" ]]
    [[ ! -L $new/$path ]]
    mkdir -p -- "$new/${path%/*}"
    [[ $(realpath -e "$new/${path%/*}") == "$new/${path%/*}" ]]
    if [[ -d /$path ]]; then
        mkdir -p -- "$new/$path"
        cp -aT -- "/$path" "$new/$path"
        diff -qr --no-dereference "/$path" "$new/$path" > "$tmp/compare"
    else
        cp -a -- "/$path" "$new/$path"
        cmp "/$path" "$new/$path"
    fi
}
# The generic image masks the previous board's USB service until a device is provisioned.
systemctl --root="$new" unmask asphalt-usb-maintenance.service ssh.service
for path in etc/machine-id etc/hostname etc/hosts etc/y700/user-configured etc/y700/bluetooth-address \
    etc/NetworkManager/system-connections etc/NetworkManager/conf.d/20-y700-usb-maintenance.conf \
    etc/systemd/system/asphalt-usb-maintenance.service etc/systemd/system/ssh.service.d/usb-maintenance.conf \
    usr/local/sbin/asphalt-usb-maintenance etc/ssh/sshd_config.d/00-y700-usb-maintenance.conf \
    root/.ssh/authorized_keys; do copy_path "$path"; done
chmod 700 "$new/root/.ssh"
for path in var/lib/NetworkManager/secret_key var/lib/bluetooth var/lib/y700-ssc; do
    if [[ -e /$path ]]; then copy_path "$path"; fi
done
if $upgrade; then
    for path in var/lib/alsa/asound.state var/lib/systemd/backlight var/lib/AccountsService/users/y700; do
        if [[ -e /$path ]]; then copy_path "$path"; fi
    done
    # The inherited enrollment supports one desktop identity.
    [[ $(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd) == y700 ]]
    awk -F: 'NR==FNR {if ($1=="y700") u=$0; next}
        $1=="y700" {if (!u || seen++) exit 2; print u; next} {print}
        END {if (seen!=1) exit 3}' /etc/passwd "$new/etc/passwd" > "$tmp/passwd"
    cat "$tmp/passwd" > "$new/etc/passwd"
    chroot "$new" getent passwd y700 | cmp -s - <(getent passwd y700)
fi
for key in /etc/ssh/ssh_host_*_key; do copy_path "${key#/}"; copy_path "${key#/}.pub"; done
# Retain the existing user's password, age and expiry without exposing its hash.
awk -F: 'NR==FNR {if ($1=="y700") u=$0; next}
    $1=="y700" {if (!u || seen++) exit 2; print u; next} {print}
    END {if (seen!=1) exit 3}' /etc/shadow "$new/etc/shadow" > "$tmp/shadow"
cat "$tmp/shadow" > "$new/etc/shadow"
[[ $(chroot "$new" passwd -S y700 | cut -d' ' -f2) == P ]]
if $upgrade; then
    groups=()
    for group in $(id -Gn y700); do
        [[ $(getent group "$group" | cut -d: -f3) == "$(chroot "$new" getent group "$group" | cut -d: -f3)" ]]
        if [[ $group != "$(id -gn y700)" ]]; then groups+=("$group"); fi
    done
    chroot "$new" usermod -G "$(IFS=,; echo "${groups[*]}")" y700
    cmp -s <(id -G y700 | tr ' ' '\n' | sort -n) <(chroot "$new" id -G y700 | tr ' ' '\n' | sort -n)
    awk -F: '$1=="y700"' /etc/shadow | cmp -s - <(awk -F: '$1=="y700"' "$new/etc/shadow")
else
    for group in $(id -Gn y700); do
        if chroot "$new" getent group "$group" >/dev/null; then chroot "$new" usermod -aG "$group" y700; fi
    done
fi
systemctl --root="$new" disable y700-usb-maintenance.service y700-maintenance-sshd.service
systemctl --root="$new" enable asphalt-usb-maintenance.service ssh.service
chroot "$new" /usr/sbin/sshd -t
chroot "$new" /usr/sbin/sshd -T > "$tmp/sshd"
[[ $(grep -c '^listenaddress ' "$tmp/sshd") == 1 ]]
if grep -Eq '^listenaddress (0\.0\.0\.0|\[::\])' "$tmp/sshd"; then
    echo 'The maintenance SSH configuration would listen on a wildcard address.' >&2
    exit 1
fi
chroot "$new" dpkg-query -W -f='${Version}\n' parole | grep -Fxq '4.18.2-1+y7002'
[[ -z $(chroot "$new" dpkg --audit) ]]
if $upgrade; then
    bash "$controller" --dev12.11 prepare-candidate "$new"
    units=$new/etc/systemd/system/y700-installed-trial-deadline
    grep -Fxq OnBootSec=4min "$units.timer"
    for unit in "$units".{timer,service}; do grep -Fxq ConditionKernelCommandLine=y700.installed_trial "$unit"; done
    [[ -z $(find "$new/etc/systemd/system" -type l -name 'y700-installed-trial-deadline.*' -print -quit) ]]
    # A live cache may change during the copy. Retry the home alone before publishing.
    copied=false
    for attempt in 1 2 3; do
        if snapshot_home >"$tmp/home-check" 2>&1; then copied=true; break; fi
        echo "Home snapshot changed or could not be verified on attempt $attempt." >&2
    done
    "$copied"
    for path in etc/machine-id etc/y700/bluetooth-address etc/y700/user-configured root/.ssh/authorized_keys; do
        cmp -s "/$path" "$new/$path"
    done
    for key in /etc/ssh/ssh_host_*_key; do cmp -s "$key" "$new$key"; cmp -s "$key.pub" "$new$key.pub"; done
    grep -Fxq "UUID=$installed_uuid / ext4 defaults 0 1" "$new/etc/fstab"
    grep -Fxq "UUID=$installed_esp /boot vfat umask=0077 0 2" "$new/etc/fstab"
    [[ $(cat "$new/etc/y700/image-id") == "y700-prc-$installed_uuid" ]]
fi
sync -f "$new"
umount -R "$new"
[[ -z $(losetup -j "$image") ]]
e2fsck -fn "$image" >/dev/null
if $upgrade; then
    [[ $(stat -c %s "$image") == 34359738368 && $(blkid -p -s UUID -o value "$image") == "$installed_uuid" &&
       $(stat -c %s "$fat") == 1073741824 && $(blkid -p -s UUID -o value "$fat") == "$installed_esp" ]]
    fsck.fat -n "$fat" >/dev/null
    printf '%s\n' 'release=dev12.11' "generic_root_sha256=$sys_sha" "generic_esp_sha256=$fat_sha" \
        "root_uuid=$installed_uuid" "fat_id=$installed_esp" 'owner_home=verified' 'account_memberships=verified' \
        'usb_ssh=verified' 'network_bluetooth_and_device_state=verified' 'counted_boot_deadline=4min' > "$dir/migration.log"
    printf '%s\n' 'dev12.11 personal files verified, USB identity retained' > "$dir/installed.ok"
    sync -f "$dir"
    mv -nT -- "$dir" "$target"
    [[ ! -e $dir ]]; sync -f "$store"
    echo 'Y700_DEV1211_PERSONAL_PASS old_root_retained=1 published=dev12.11 root_size_gib=32'
    exit 0
fi
printf '%s\n' 'dev12.10 personal files verified, USB identity retained' > "$dir/installed.ok"
sync -f "$dir"
echo 'Y700_INSTALL_PERSONAL_PASS root_size_gib=32 home=verified account=retained wifi=verified bluetooth=verified usb_ssh=validated'
