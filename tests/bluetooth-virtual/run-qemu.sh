#!/usr/bin/env bash
# Isolated ARM VM with a read-only product root.
set -euo pipefail
if (( $# < 6 || $# > 7 )); then
    echo 'Usage: run-qemu.sh ROOT Y700_KERNEL_BUILD BUSYBOX_ARM64 UV_ARM64 BLUEZ_5.82_SRC BTVIRT_ARM64 [--classic|--cold-classic|--cold-le-login|--cold-reboot|--cold-reboot-linked|--windows-report|--blueman|--blueman-keyboard]' >&2
    exit 2
fi
root=$(realpath -e "$1")
kernel=$(realpath -e "$2")
busybox=$(realpath -e "$3")
uv=$(realpath -e "$4")
bluez=$(realpath -e "$5")
btvirt=$(realpath -e "$6")
marker=Y700_VIRTUAL_HOG_PASS
extra_cmdline=
shutdown_case=
variant=${7:-}
image=$kernel/arch/arm64/boot/Image
greeter=${Y700_BT_GREETER:-0}
login=0
if [[ $variant == --cold-le-login ]]; then
    login=1; greeter=1; export Y700_BT_TYPING=1
    image=$(realpath -e "${Y700_BT_RELEASE_KERNEL:?dev12.12 kernel.efi}")
    printf '%s  %s\n' 0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$image" | sha256sum -c -
fi
[[ $greeter == 0 || ( $greeter == 1 && ( $variant == --cold-classic || $login == 1 ) ) ]] || exit 2
if (( $# == 7 )); then
    case "$7" in
        --classic) extra_cmdline=y700.virtual_classic=1; marker=Y700_VIRTUAL_CLASSIC_INPUT_PASS ;;
        --blueman|--blueman-keyboard)
            [[ -n ${XORG_DUMMY_DEB:-} && ${Y700_BT_TYPING:-0} == 0 ]] || exit 2
            extra_cmdline=y700.blueman_pair=1; marker=Y700_BLUEMAN_HOG_PASS
            if [[ $7 == --blueman-keyboard ]]; then
                [[ ${Y700_BT_ROOT_FORMAT:-} == raw ]]
                echo "5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3  $root" | sha256sum --strict -c -
                image=$(realpath -e "${Y700_BT_RELEASE_KERNEL:?dev12.12 kernel.efi}")
                printf '%s  %s\n' 0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$image" | sha256sum -c -
                extra_cmdline+=" y700.blueman_keyboard=1"; marker=Y700_BLUEMAN_KEYBOARD_PASS
            fi ;;
        --windows-report)
            [[ -n ${XORG_DUMMY_DEB:-} && -n ${Y700_WINDOWS_REPORT_DIR:-} && ${Y700_BT_TYPING:-0} == 0 ]] || exit 2
            extra_cmdline=y700.windows_report=1; marker=Y700_WINDOWS_REPORT_PASS
            if [[ ${Y700_EXPECT_LEGACY_MOUSE:-0} == 1 ]]; then extra_cmdline+=" y700.legacy_mouse=1"; fi ;;
        --cold-classic) extra_cmdline=y700.virtual_classic=1; marker=Y700_COLD_SEED_PASS ;;
        --cold-reboot) marker=Y700_COLD_SEED_PASS ;;
        --cold-le-login) marker=Y700_COLD_SEED_PASS; extra_cmdline=y700.virtual_login=1 ;;
        --cold-reboot-linked) marker=Y700_COLD_SEED_PASS; shutdown_case=y700.virtual_linked_shutdown=1 ;;
        *) exit 2 ;;
    esac
fi
root_format=${Y700_BT_ROOT_FORMAT:-qcow2}
case $root_format in qcow2|raw) ;; *) echo 'Unsupported root format' >&2; exit 2 ;; esac
if [[ ${Y700_BT_TYPING:-0} == 1 ]]; then
    [[ -n ${XORG_DUMMY_DEB:-} && ( $marker != Y700_COLD_SEED_PASS || ${7:-} == --cold-classic || $login == 1 ) ]] || {
        echo 'Typing requires XORG_DUMMY_DEB and a supported text profile' >&2; exit 2;
    }
    extra_cmdline+=" y700.virtual_typing=1"
    if [[ $marker != Y700_COLD_SEED_PASS ]]; then
        printf 'TYPING_ROOT format=%s sha256=' "$root_format"; sha256sum "$root"
    fi
fi
fixture=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-virtual-hid.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/module" "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test}
printf '%s  %s\n' 4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$kernel/arch/arm64/boot/Image" | sha256sum -c -
printf '%s  %s\n' \
    929e7d251411b8b2ce48b8c2980e54d466591920d99a4c18c201897a8a273736 "$kernel/drivers/bluetooth/hci_vhci.c" \
    48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83 "$kernel/Module.symvers" \
    a190508dd5bafd048ead4404535610c8c827181917cb569530f8de36ad329fd6 "$bluez/test/example-gatt-server" \
    48cda541a25514609bcdd0ea6f9787cc2729f232c37bb8915c714ad8f9ac7b28 "$bluez/test/example-advertisement" \
    b801ccb950de2e511f351f7e346a2cdc519fef1e41634f056850dd7d36dbf742 "$btvirt" | sha256sum -c -
if [[ -n ${XORG_DUMMY_DEB:-} ]]; then
    printf '%s  %s\n' 5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$XORG_DUMMY_DEB" | sha256sum -c -
    cp "$XORG_DUMMY_DEB" "$work/init/test/dummy.deb"
    cp "$fixture/"{desktop.py,desktop-xorg.sh,dummy.conf} "$work/init/test/"
fi
if [[ $greeter == 1 ]]; then
    cp "$fixture/"{greeter.py,greeter-seat.sh,greeter.service} "$work/init/test/"
fi
if (( login )); then cp "$fixture/greeter_login.py" "$work/init/test/"; fi
cp "$kernel/drivers/bluetooth/hci_vhci.c" "$work/module/"
echo 'obj-m += hci_vhci.o' > "$work/module/Makefile"
make -s -C "$kernel" M="$work/module" ARCH=arm64 LLVM="${LLVM:--21}" modules
cp "$work/module/hci_vhci.ko" "$work/init/test/"
cp "$bluez/test/example-gatt-server" "$work/init/test/gatt.py"
cp "$bluez/test/example-advertisement" "$work/init/test/adv.py"
cp "$fixture/"{central.py,peer.py,classic.py,keyboard.py,cold-boot.py,guest.sh} "$work/init/test/"
if [[ $variant == --windows-report ]]; then
    cp "$Y700_WINDOWS_REPORT_DIR/"{report-map.bin,motion.bin} "$work/init/test/"
    cp "$fixture/../windows-ble-hid/"{verify-report.py,capture-input.py} "$work/init/test/"
fi
if [[ $variant == --blueman* ]]; then
    cp "$fixture/../blueman-pairing/"{probe.py,numeric-link.py,numeric-session.sh,numeric-trace.py} "$work/init/test/"
    if [[ $variant == --blueman-keyboard ]]; then
        cp "$fixture/../blueman-pairing/"{keyboard-link.py,keyboard-trace.py} "$work/init/test/"
    fi
fi
install -m755 "$busybox" "$work/init/bin/busybox"
install -m755 "$uv" "$work/init/test/uv"
install -m755 "$btvirt" "$work/init/test/btvirt"
cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
rootdev=/dev/vda
if [ "$(cat /sys/block/vda/ro)" != 1 ]; then rootdev=/dev/vdb; fi
[ "$(cat "/sys/block/${rootdev##*/}/ro")" = 1 ]
mount -t ext4 -o ro,noload "$rootdev" /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for d in dev proc sys; do mount --bind "/$d" "/guest/$d"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/y700-virtual-hid
if grep -qw y700.virtual_greeter=1 /proc/cmdline; then
    cp -a /test/. /guest/opt/y700-virtual-hid/
    cp /test/greeter.service /guest/etc/systemd/system/y700-hid-greeter.service
    if ! grep -qw y700.virtual_login=1 /proc/cmdline; then
        ln -sf /dev/null /guest/etc/systemd/system/bluetooth.service
    else
        mkdir -p /guest/etc/systemd/system/y700-hid-greeter.service.d
        printf '[Service]\nTimeoutStartSec=420\n' > /guest/etc/systemd/system/y700-hid-greeter.service.d/timeout.conf
    fi
    exec switch_root /guest /sbin/init
fi
mount --bind /test /guest/opt/y700-virtual-hid
rc=0
chroot /guest /bin/bash /opt/y700-virtual-hid/guest.sh || rc=$?
echo "Y700_VIRTUAL_HID_EXIT=$rc"
poweroff -f
INIT
chmod 755 "$work/init/init"
(cd "$work/init"; find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$work/initrd")
args=()
state_disk=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
if [[ $marker == Y700_COLD_SEED_PASS ]]; then
    root_sum=18c58b29bad672bc0a3971f4e68b49c3c27101a9759f87da8acde640ef4b02e2
    if [[ $variant == --cold-classic ]]; then
        [[ $root_format == raw && ${Y700_BT_TYPING:-0} == 1 ]]
        root_sum=dd885eb7bc88e3fb87b0567ff7f382afbe079363910d6f0fd5b4bb41935e220a
    fi
    if (( login )); then
        [[ $root_format == raw ]]
        root_sum=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
    fi
    printf '%s  %s\n' "$root_sum" "$root" | sha256sum -c -
    install -m600 /dev/null "$work/bonds.ext4"
    truncate -s 16M "$work/bonds.ext4"
    mkfs.ext4 -q -m0 -L Y700_BT_TEST "$work/bonds.ext4"
    state_disk=(-drive "if=none,id=bonds,format=raw,file=$work/bonds.ext4" -device virtio-blk-device,drive=bonds)
    bond_cmdline="$extra_cmdline $shutdown_case"
    extra_cmdline="y700.virtual_bond=seed $bond_cmdline"
fi
boot() {
    local ram=680 bound=190 cpus=2
    if [[ $variant == --blueman* ]]; then ram=1024; bound=260; fi
    if [[ $extra_cmdline == *y700.virtual_greeter=1* ]]; then ram=1400; bound=350; fi
    if [[ $extra_cmdline == *y700.virtual_greeter=1* && $login == 1 ]]; then ram=2304; cpus=4; bound=460; fi
    timeout -k 4 "$bound" "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" \
    -machine virt,gic-version=3 -cpu max -m "$ram" -smp "$cpus" -nodefaults -no-user-config \
    -display none -monitor none -serial stdio -nic none -no-reboot \
    -kernel "$image" -initrd "$work/initrd" \
    -append "console=ttyAMA0 loglevel=4 y700.virtual_hid=1 $extra_cmdline panic=4" \
    -drive "if=none,id=root,format=$root_format,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    "${state_disk[@]}" \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/run.log"
    grep -Fxq "$marker" "$work/run.log"
    grep -Fxq Y700_VIRTUAL_HID_EXIT=0 "$work/run.log"
    if [[ $login == 1 && $extra_cmdline == *y700.virtual_greeter=1* ]]; then
        for evidence in LE_LOGIN_BLUEZ_STOCK_SERVICE_ACTIVE Y700_LE_PAM_XFCE_PASS Y700_LE_SAME_SESSION_UNLOCK_PASS \
                        AUTOMATIC_WITH_ORIGINAL_RECIPROCAL_KEYS 'HCI_AES_CCM_VERIFIED pairing_exchange=no'; do
            grep -Fxq "$evidence" "$work/run.log"
        done
    fi
    if [[ $variant == --cold-classic ]]; then
        if [[ $extra_cmdline == *y700.virtual_greeter=1* ]]; then
            grep -Fxq Y700_ARCTICA_BONDED_USERNAME_PASS "$work/run.log"
        else
            grep -Fxq Y700_GTK_BT_TYPING_PASS "$work/run.log"
            grep -Fxq Y700_GTK_HID_INPUT_PASS "$work/run.log"
        fi
    fi
}
boot
if [[ $marker == Y700_COLD_SEED_PASS ]]; then
    first=$(grep -Ex 'COLD_BOOT_ID=[[:xdigit:]-]{36}' "$work/run.log")
    extra_cmdline="y700.virtual_bond=resume $bond_cmdline"
    if [[ $greeter == 1 ]]; then
        extra_cmdline+=" y700.virtual_greeter=1 fstab=no systemd.unit=y700-hid-greeter.service systemd.show_status=no"
    fi
    marker=Y700_COLD_RESUME_PASS
    boot
    second=$(grep -Ex 'COLD_BOOT_ID=[[:xdigit:]-]{36}' "$work/run.log")
    [[ $first != "$second" ]]
    echo Y700_COLD_BOND_PERSISTENCE_PASS
    exit 0
fi
if [[ -n ${XORG_DUMMY_DEB:-} ]]; then
    if [[ $variant == --blueman-keyboard ]]; then
        [[ $(grep -Fxc Y700_GTK_HID_INPUT_PASS "$work/run.log") == 2 ]]
        exit 0
    fi
    if [[ $variant == --blueman ]]; then
        grep -Fxq Y700_GTK_HID_INPUT_PASS "$work/run.log"
        extra_cmdline+=" y700.blueman_deny=1"
        marker=Y700_BLUEMAN_HOG_REJECT_PASS
        boot
        exit 0
    fi
    if [[ $variant == --windows-report ]]; then
        if [[ ${Y700_EXPECT_LEGACY_MOUSE:-0} != 1 ]]; then
            grep -Fxq Y700_GTK_HID_INPUT_PASS "$work/run.log"
            grep -Fxq F15_PRESS_RELEASE_AND_RELATIVE_XY_VERIFIED "$work/run.log"
        fi
        exit 0
    fi
    expected=3
    [[ $marker != Y700_VIRTUAL_CLASSIC_INPUT_PASS ]] || expected=2
    [[ $(grep -Fxc Y700_GTK_HID_INPUT_PASS "$work/run.log") == "$expected" ]]
    if [[ ${Y700_BT_TYPING:-0} == 1 ]]; then
        [[ $(grep -Fxc Y700_GTK_BT_TYPING_PASS "$work/run.log") == "$expected" ]]
    fi
fi
