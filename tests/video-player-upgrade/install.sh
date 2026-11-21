#!/bin/bash
# Run inside the target dev12.9 chroot or RAM desktop.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022
die() { echo "$*" >&2; exit 1; }
case ${1:-check} in
    check|install|verify) target=candidate ;;
    rollback|verify-stock) target=stock ;;
    *) die 'Usage: install.sh [check|install|verify|rollback|verify-stock]' ;;
esac
[[ $# -le 1 ]] || die 'Unexpected arguments'
action=${1:-check}
mutate=false
if [[ $action == install || $action == rollback ]]; then
    [[ $EUID == 0 ]] || die 'Root is required to install or roll back'
    mutate=true
fi
bundle=$(cd "$(dirname "$0")" && pwd -P)
cd "$bundle"
sha256sum --strict --quiet -c SHA256SUMS
sha256sum --strict --quiet -c payload.sha256
stock=4.18.2-1
candidate=4.18.2-1+y7002
target_version=${!target}
record=/var/lib/y700/build
plugin=/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so
pending=$record/.y700-player-update-pending
stage=${plugin%/*}/.y700-player-update-next
tag=y700-player-update-dev12.9-v1
regular() { [[ -f $1 && ! -L $1 && $(realpath -e -- "$1") == "$1" ]]; }
owned() { regular "$1" && [[ $(stat -c '%u:%g:%h' -- "$1") == 0:0:1 ]]; }
[[ $(dpkg --print-architecture) == arm64 ]] || die 'Requires an arm64 target'
for dir in "$record" "${plugin%/*}"; do
    [[ $(realpath -e "$dir") == "$dir" && -d $dir && $(stat -c %u "$dir") == 0 ]] ||
        die "Unrecognized target directory: $dir"
    [[ -z $(find "$dir" -maxdepth 0 -perm /022 -print) ]] || die "Writable target directory: $dir"
done
# flock the existing directory, including for read-only checks. No lockfile is created.
exec {lock}<"$record"
flock --exclusive "$lock"
while read -r digest file; do regular "$file" || die "Missing or redirected baseline file: $file"; done < baseline.sha256
sha256sum --strict --quiet -c baseline.sha256
owned "$plugin" && [[ $(stat -c %a "$plugin") == 644 ]] || die 'Unexpected private plugin file or mode'
if cmp -s "$plugin" stock/libgstvideo4linux2.so; then installed_plugin=stock
elif cmp -s "$plugin" candidate/libgstvideo4linux2.so; then installed_plugin=candidate
else die 'Unrecognized private Iris plugin'; fi
recover=false
if [[ -e $pending || -L $pending ]]; then
    owned "$pending" && [[ $(stat -c %a "$pending") == 600 && $(cat "$pending") == "$tag" ]] ||
        die 'Unrecognized pending transaction'
    recover=true
fi
if [[ -e $stage || -L $stage ]]; then
    "$recover" && owned "$stage" || die 'Unrecognized staging file'
fi
version=$(dpkg-query -W '-f=${Version}' parole)
[[ $version == "$stock" || $version == "$candidate" ]] || die "Unrecognized Parole: $version"
state=$(dpkg-query -W '-f=${db:Status-Status}' parole)
# Normalize just Parole to compare the full known 1,240-package inventory.
# A retry can follow dpkg unpack/configure or deferred Debian trigger processing.
inventory=$(dpkg-query -W '-f=${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' |
    awk -F '\t' -v base="$stock" -v retry="$recover" 'BEGIN{OFS=FS}
        $4 == "config-files" || $4 == "not-installed" { next }
        $4 != "installed" && !(retry == "true" && ($1 == "parole" || $4 ~ /^triggers-(pending|awaited)$/)) { exit 1 }
        { if ($1 == "parole") $2=base; print $1,$2,$3 }' | sort | sha256sum)
[[ ${inventory%% *} == 89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d ]] ||
    die 'Target inventory differs from sealed dev12.9'
check_parole() {
    local component expected report
    case $1 in
        "$stock") component=stock ;;
        "$candidate") component=candidate ;;
        *) return 1 ;;
    esac
    expected=$(dpkg-deb --fsys-tarfile "$component/parole_${1}_arm64.deb" |
        tar -xO -f - ./usr/bin/parole | sha256sum) || return 1
    expected=${expected%% *}
    regular /usr/bin/parole && printf '%s  /usr/bin/parole\n' "$expected" | sha256sum --quiet -c - &&
        report=$(dpkg --verify parole) && [[ -z $report ]]
}
if [[ $state == installed ]]; then
    check_parole "$version" || die 'Installed Parole files differ from their known package'
elif ! "$recover"; then
    die "Parole is $state outside a known update"
fi
if ! "$recover"; then [[ -z $(dpkg --audit) ]] || die 'The base dpkg state needs attention'; fi
printf 'dev12.9 parole=%s status=%s private_iris=%s pending=%s\n' "$version" "$state" "$installed_plugin" "$recover"
if [[ $action == check ]]; then exit 0; fi
if ! "$mutate"; then
    [[ $version == "$target_version" && $installed_plugin == "$target" && $state == installed && $recover == false ]] ||
        die "The requested $target pair is not fully installed"
    exit 0
fi
if [[ $version == "$target_version" && $installed_plugin == "$target" && $recover == false ]]; then exit 0; fi
if ! "$recover"; then
    # Publish a complete marker before dpkg sees any files. A retry can choose either direction.
    marker=$(mktemp "$record/.y700-player-marker.XXXXXXXX")
    trap 'rm -f -- "$marker"' EXIT
    printf '%s\n' "$tag" > "$marker"
    mv -T "$marker" "$pending"
    trap - EXIT
fi
if [[ -e $stage ]]; then rm -- "$stage"; fi
if [[ $version != "$target_version" || $state != installed || $recover == true ]]; then
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$target/parole_${target_version}_arm64.deb"
fi
[[ $(dpkg-query -W '-f=${Version} ${db:Status-Status}' parole) == "$target_version installed" ]] ||
    die 'Parole package did not finish configuring'
check_parole "$target_version" || die 'Parole payload verification failed'
[[ -z $(dpkg --audit) ]] || die 'dpkg has unfinished work'
if [[ $installed_plugin != "$target" ]]; then
    # The two ELF files have the same size. GStreamer also checks integer-second mtime.
    previous=$(stat -c %Y "$plugin")
    timestamp=$(date +%s)
    if (( timestamp <= previous )); then timestamp=$((previous + 1)); fi
    install -o root -g root -m644 "$target/libgstvideo4linux2.so" "$stage"
    cmp "$stage" "$target/libgstvideo4linux2.so"
    touch -d "@$timestamp" "$stage"
    mv -fT "$stage" "$plugin"
fi
sha256sum --strict --quiet -c baseline.sha256
cmp "$plugin" "$target/libgstvideo4linux2.so"
rm -- "$pending"
echo "Verified complete $target pair"
