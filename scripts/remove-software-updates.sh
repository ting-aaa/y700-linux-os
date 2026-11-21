#!/bin/bash
# Roll back the packages added by the documented six-package tablet installation.
set -euo pipefail
dir=$(dirname "$(realpath -e "$0")")
[[ $EUID == 0 && -f $dir/added-packages && ! -L $dir/added-packages ]]
[[ $(stat -c '%u:%a' "$dir") == 0:700 && $(stat -c %u "$dir/added-packages") == 0 ]]
mapfile -t added < "$dir/added-packages"
declare -a installed=()
for pkg in "${added[@]}"; do
    case $pkg in
        y700-software-updates|gnome-package-updater|gnome-packagekit-common|packagekit|libpackagekit-glib2-18|gir1.2-packagekitglib-1.0) ;;
        *) echo "Unknown package in installation record: $pkg" >&2; exit 1 ;;
    esac
    status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || :)
    case $status in ''|not-installed) continue ;; esac
    installed+=("$pkg")
done
if (( ${#installed[@]} )); then
    dpkg --no-act --purge "${installed[@]}"
    dpkg --purge "${installed[@]}"
fi
