#!/usr/bin/env bash
# Run as y700 on the installed tablet, after manual touch mapping is validated.
set -euo pipefail
test "$(id -un)" = y700
test "$HOME" = /home/y700
test "$(cat /etc/y700/image-id)" = asphalt-prc-debian13-xfce-7.3.4-v1
command -v xinput >/dev/null || { echo 'Install xinput before installing this helper.' >&2; exit 1; }
command -v xrandr >/dev/null
command -v flock >/dev/null
here=$(cd -- "$(dirname -- "$0")" && pwd)
stamp=$(date +%Y%m%d-%H%M%S)
bin="$HOME/.local/bin/y700-display"
entry="$HOME/.config/autostart/y700-touch-sync.desktop"
for target in "$bin" "$entry"; do
    test ! -L "$target" || { echo "Refusing to replace symlink: $target" >&2; exit 1; }
    if test -e "$target"; then
        grep -Eq '^# Y700_TOUCH_SYNC_MANAGED_V1$|^X-Y700-Touch-Sync-Managed=true$' "$target" || {
            echo "Existing file is not managed by this helper: $target" >&2; exit 1;
        }
    fi
done
mkdir -p -- "${bin%/*}" "${entry%/*}"
for target in "$bin" "$entry"; do
    if test -e "$target"; then cp -a -- "$target" "$target.before-$stamp"; fi
done
install -m 755 "$here/y700-display" "$bin"
install -m 644 "$here/y700-touch-sync.desktop" "$entry"
printf 'Installed for the next Xfce login. Start in this desktop session with:\n%s --watch\n' "$bin"
