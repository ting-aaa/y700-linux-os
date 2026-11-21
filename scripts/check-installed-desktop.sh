#!/bin/bash
# Read-only postboot observations on the PRC board. Never open a media or input stream.
set +x
set -uo pipefail
export LC_ALL=C
shopt -s nullglob
mode=candidate
edition=dev12.10
inner_uuid=171a4adb-916b-4763-9e6f-722b4a99988f
inner_fat=171A-4ADB
notes=c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564
case ${1:-} in
    --baseline) mode=baseline; shift ;;
    --dev12.11)
        edition=dev12.11
        inner_uuid=c0e447e4-82db-59ee-91d6-0e1ec9d5f45e
        inner_fat=31EC-3084
        notes=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
        shift ;;
esac
[[ $# == 0 && $EUID == 0 ]] || { echo 'Usage as root: check-installed-desktop.sh [--baseline|--dev12.11]' >&2; exit 2; }
failed=0
check() {
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then printf 'PASS %s\n' "$name"
    else printf 'FAIL %s\n' "$name"; failed=$((failed+1)); fi
}
hash_is() { [[ -f $1 && $(sha256sum "$1" 2>/dev/null | cut -d' ' -f1) == "$2" ]]; }
property() { timeout 2 busctl --system --auto-start=no --timeout=1s get-property "$@" 2>/dev/null; }
unit() { timeout 2 systemctl show -p ActiveState --value "$1" 2>/dev/null; }
board() {
    grep -azFxq lenovo,asphalt /proc/device-tree/compatible &&
        [[ $(tr -d '\0' </proc/device-tree/region_country) == PRC && $(uname -r) == 7.3.4-asphalt-prc ]]
}
if ! board 2>/dev/null; then echo 'FAIL unexpected_board_or_kernel'; exit 1; fi
echo "BOARD_DESKTOP_CHECK mode=$mode"
check kernel_notes hash_is /sys/kernel/notes "$notes"
check systemd_pid1 test "$(cat /proc/1/comm)" = systemd
outer_uuid=ef306764-2315-4235-8796-69e2c9b61946
origin=/run/initramfs/backing
loop_is() {
    local loop image=$origin/var/lib/y700-trial/$edition/$2
    loop=$(findmnt -nro SOURCE -M "$1") || return 1
    [[ $loop =~ ^/dev/loop[0-9]+$ && -f $image && ! -L $image &&
       $(stat -c '%u:%g:%a:%h:%s' "$image") == "0:0:600:1:$3" &&
       $(losetup --raw -nO BACK-INO "$loop") == "$(stat -c %i "$image")" &&
       $(losetup --raw -nO BACK-MAJ:MIN "$loop") == "$(findmnt -nro MAJ:MIN -M "$origin")" &&
       $(losetup --raw -nO OFFSET "$loop") == 0 ]]
}
if [[ $mode == candidate ]]; then
    # Refuse to inspect personal baseline files if storage identity is unexpected.
    if ! [[ $(findmnt -nro UUID -M "$origin") == "$outer_uuid" &&
            $(findmnt -nro UUID -M /) == "$inner_uuid" &&
            $(findmnt -nro UUID -M /boot) == "$inner_fat" ]] ||
       ! loop_is / root.ext4 34359738368 || ! loop_is /boot linux-boot.fat 1073741824; then
        echo 'FAIL candidate_storage_identity'; exit 1
    fi
    echo 'PASS candidate_storage_identity'
    check release_option grep -Fqw "y700.release=$edition" /proc/cmdline
    check file_option grep -Fqw y700.media=file /proc/cmdline
    if grep -Fqw y700.recovery=journal /proc/cmdline; then
        printf 'OBS boot_recovery=journal inner_efi_mode=%s\n' "$(findmnt -nro OPTIONS -M /boot | cut -d, -f1)"
    fi
    check release_receipt hash_is /var/lib/y700/build/video-player-update.lock.json 39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb
    check parole_binary hash_is /usr/bin/parole 76cb6ec197596e29ee5a720160b0b1683c38864b80f10dec6759a8fa5a49f2cb
    check iris_private_plugin hash_is /usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so a64bdb5bf9e4454f371638cf17c2564c3cbe3a3bc379ba5151de3c689f4a69f0
    records=$(dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort)
    check installed_packages_1240 test "$(printf '%s\n' "$records" | wc -l)" = 1240
    package_sha=$(printf '%s\n' "$records" | sha256sum | cut -d' ' -f1)
    if [[ $edition == dev12.11 ]]; then
        case $package_sha in
            be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d)
                echo 'PASS installed_versions dev12.11' ;;
            5e7c63ae4efdce57f57fa983038f5e37cce0ec1c763e56fdce1c2314ac50ca08|28746a498c221806b08e66de6e93595a18fb6a0fb6d1c7c2a3e1ee9fe652ca71)
                echo 'PASS installed_versions dev12.11 with Chromium graphics setting'
                if [[ $package_sha == 28746a498c221806b08e66de6e93595a18fb6a0fb6d1c7c2a3e1ee9fe652ca71 ]]; then
                    check brightness_slider hash_is /usr/libexec/y700-tablet-brightness e5df07598109b52c82824ec36f0b42ee3959edd752426821a195665f2e57534c
                fi
                check chromium_launcher_policy hash_is /etc/chromium.d/99-y700-software-rendering d6abf4aae2553dbd8fad313adc1677419f7c188ffc7ea507375ce5d64eff092a
                check chromium_settings_entry hash_is /usr/share/applications/y700-chromium-graphics.desktop 8619926e6f99f3a3f58478f125edb04a41e6984c8502078f32aa6d3c29df748f
                check chromium_settings_app hash_is /usr/libexec/y700-chromium-graphics 0aaf19304acea09724fd013dce7e1fe45f6ddaa964c108bddbc6e90d48c7632b
                check chromium_settings_schema hash_is /usr/share/glib-2.0/schemas/org.y700.chromium.gschema.xml fabeb3d9625e047d8ab180f8540780dd6bb301717b5360aa097cb50934c531e2 ;;
            *) check installed_versions false ;;
        esac
        check camera_receipt hash_is /var/lib/y700/build/camera-autofocus.lock.json 411490734a965ca1405ca33e3b9a1fcb79a1fbad196d947cf3736cb66b1b41b1
        check image_version grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
    else
        case $package_sha in
            ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3)
                echo 'PASS installed_versions dev12.10' ;;
            2d180b436086b9015044bff4053c314de4b63bce4f5406baffcd1ebce79a67d8)
                echo 'PASS installed_versions dev12.10 with Wi-Fi SAE update' ;;
            be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d)
                echo 'PASS installed_versions dev12.10 with Wi-Fi SAE and camera updates' ;;
            *) check installed_versions false ;;
        esac
    fi
    check migration_receipt grep -Fxq "$edition personal files verified, USB identity retained" "$origin/var/lib/y700-trial/$edition/installed.ok"
    check machine_identity_retained cmp -s /etc/machine-id "$origin/etc/machine-id"
    check bluetooth_identity_retained cmp -s /etc/y700/bluetooth-address "$origin/etc/y700/bluetooth-address"
    check ssh_public_identity_retained cmp -s /etc/ssh/ssh_host_ed25519_key.pub "$origin/etc/ssh/ssh_host_ed25519_key.pub"
    # Session caches change at login. Only compare the ordinary home startup file here.
    if [[ -f $origin/home/y700/.profile ]]; then
        if cmp -s /home/y700/.profile "$origin/home/y700/.profile"; then echo 'OBS home_profile=matches_baseline'
        else echo 'OBS home_profile=changed'; fi
    fi
else
    if [[ $(findmnt -nro UUID -M /) != "$outer_uuid" || $(findmnt -nro UUID -M /boot) != B6D4-FA81 ||
          $(cat /etc/y700/image-id 2>/dev/null) != asphalt-prc-debian13-xfce-7.3.4-v1 ]]; then
        echo 'FAIL baseline_storage_identity'; exit 1
    fi
    echo 'PASS original_baseline_running'
fi

esp=$(findmnt -nro TARGET -S UUID=B6D4-FA81 | head -1)
default=outer_esp_unmounted
if [[ -n $esp && -r $esp/loader/loader.conf ]]; then
    pattern=$(awk 'tolower($1)=="default" {print $2}' "$esp/loader/loader.conf")
    case $pattern in
        debian.conf) default=original_debian ;;
        y700-file-12-10.conf) default=dev12.10_installed ;;
        y700-recovery-12-10.conf) default=dev12.10_recovery ;;
        y700-file-12-11.conf) default=dev12.11_installed ;;
        y700-installed-*) default=counted_trial ;;
        *) default=other ;;
    esac
    check original_efi_entry test -s "$esp/loader/entries/debian.conf"
fi
echo "OBS outer_efi_default=$default"
check migrated_user test "$(id -u y700 2>/dev/null):$(id -g y700 2>/dev/null)" = 1000:1000
check user_password_configured test "$(passwd -S y700 2>/dev/null | awk '{print $2}')" = P
check home_owner test "$(stat -c '%u:%g' /home/y700 2>/dev/null)" = 1000:1000
for service in lightdm ssh asphalt-usb-maintenance systemd-logind NetworkManager bluetooth; do
    state=$(unit "$service")
    case $state in active|inactive|activating|deactivating|failed) ;; *) state=unknown;; esac
    printf 'OBS service=%s state=%s\n' "$service" "$state"
    case $service in lightdm|ssh|systemd-logind) check "${service}_active" test "$state" = active;; esac
done
seat=$(timeout 2 loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
seat_state=transition_or_absent
if [[ $seat =~ ^[[:alnum:]_-]+$ ]]; then
    class=$(timeout 2 loginctl show-session "$seat" -p Class --value 2>/dev/null)
    uid=$(timeout 2 loginctl show-session "$seat" -p User --value 2>/dev/null)
    if [[ $class == greeter ]]; then seat_state=greeter
    elif [[ $class == user && $uid == 1000 ]]; then seat_state=user; fi
fi
echo "OBS seat0=$seat_state"
for proc in xfce4-session xfce4-panel pipewire wireplumber; do
    if pgrep -u 1000 -x "$proc" >/dev/null; then state=present; else state=absent; fi
    echo "OBS user_process=$proc state=$state"
done

wifi=0; connected=0
for net in /sys/class/net/*; do
    [[ -e $net/phy80211 || -d $net/wireless ]] || continue
    wifi=$((wifi+1))
    [[ $(cat "$net/operstate" 2>/dev/null) != up ]] || connected=$((connected+1))
done
enabled=$(property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager WirelessEnabled)
case $enabled in 'b true') enabled=yes;; 'b false') enabled=no;; *) enabled=unavailable;; esac
echo "OBS wifi_interfaces=$wifi link_up=$connected manager_radio_enabled=$enabled"
controllers=0; powered=0
for hci in /sys/class/bluetooth/hci*; do
    [[ ${hci##*/} =~ ^hci[0-9]+$ ]] || continue
    controllers=$((controllers+1))
    if [[ $(property org.bluez "/org/bluez/${hci##*/}" org.bluez.Adapter1 Powered) == 'b true' ]]; then powered=$((powered+1)); fi
done
echo "OBS bluetooth_controllers=$controllers powered=$powered"
touch=0
for input in /sys/class/input/event*/dev; do
    if grep -Fxq E:ID_INPUT_TOUCHSCREEN=1 "/run/udev/data/c$(cat "$input")" 2>/dev/null; then touch=$((touch+1)); fi
done
cards=0
for card in /sys/class/drm/card*; do [[ ${card##*/} =~ ^card[0-9]+$ ]] && cards=$((cards+1)); done
render=(/dev/dri/renderD*); panel=(/sys/class/drm/card*-DSI-*); lights=(/sys/class/backlight/*)
echo "OBS touch_events=$touch drm_cards=$cards drm_render_nodes=${#render[@]} dsi_connectors=${#panel[@]} backlights=${#lights[@]}"
pcm=/proc/asound/pcm
play=$(grep -Ec 'playback [1-9]' "$pcm" 2>/dev/null || :); cap=$(grep -Ec 'capture [1-9]' "$pcm" 2>/dev/null || :)
amps=0
for chip in /sys/bus/i2c/devices/*/name; do
    if [[ $(cat "$chip" 2>/dev/null) == *cs35l45* && -L ${chip%/*}/driver ]]; then amps=$((amps+1)); fi
done
soundcards=(/proc/asound/card[0-9]*)
echo "OBS alsa_cards=${#soundcards[@]} playback_pcms=${play:-0} capture_pcms=${cap:-0} speaker_amp_drivers=$amps"
main=0; front=0; macro=0
for sensor in /sys/class/video4linux/v4l-subdev*/name; do
    name=$(cat "$sensor" 2>/dev/null)
    case ${name,,} in hi1339*) main=1;; s5k4h7*) front=1;; sc202cs*) macro=1;; esac
done
echo "OBS camera_subdevices rear_main=$main front=$front rear_macro=$macro"
slpi=unavailable
for dsp in /sys/class/remoteproc/remoteproc*; do
    case $(readlink -f "$dsp") in */2400000.remoteproc/*)
        state=$(cat "$dsp/state" 2>/dev/null)
        case $state in offline|running|attached|crashed|suspended|detached) slpi=$state;; *) slpi=unknown;; esac;;
    esac
done
echo "OBS slpi=$slpi"
echo "BOARD_DESKTOP_RESULT mode=$mode core_failures=$failed"
((failed == 0))
