set -euo pipefail
cat /proc/sys/kernel/random/boot_id
seat=$(loginctl show-seat seat0 -p ActiveSession --value)
[[ -n $seat ]]
loginctl show-session "$seat" -p Id -p Active -p LockedHint -p Type
systemctl show lightdm ssh NetworkManager bluetooth upower -p Id -p InvocationID
for path in brightness bl_power; do cat "/sys/class/backlight/ktz8866-backlight/$path"; done
for unit in /sys/class/remoteproc/remoteproc*; do
   if [[ $(cat "$unit/name") == *slpi* ]]; then cat "$unit/state"; fi
done
findmnt -nro SOURCE,FSTYPE,OPTIONS /
findmnt -nro SOURCE,FSTYPE,OPTIONS --mountpoint /boot
cat /proc/swaps
findmnt -nro SOURCE,FSTYPE,OPTIONS -T /run/initramfs/backing
ip -o addr show | awk '{print $1,$2,$3,$4}' | sha256sum
ip route show | sha256sum
losetup --list --noheadings --output NAME,BACK-FILE | sort | sha256sum
for f in /sys/fs/ext4/*/errors_count; do cat "$f"; done
for name in /sys/bus/i2c/devices/*/name; do
    case $(cat "$name") in hi1339|s5k4h7|sc202cs)
        power=$(dirname "$name")/power
        cat "$name" "$power/runtime_status" "$power/runtime_active_time"
        ;;
    esac
done
