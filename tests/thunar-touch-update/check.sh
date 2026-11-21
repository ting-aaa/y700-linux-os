#!/bin/bash
# ARM64 dpkg in a private, disposable overlay of the dev12.13 release.
set -euo pipefail
if [[ ${1:-} != --inside ]]; then
    [[ $EUID == 0 && $# == 2 ]] || { echo 'Usage as root: check.sh SEALED_ROOT.ext4 BUNDLE.tar' >&2; exit 2; }
    exec unshare --mount --propagation private --net --pid --fork --kill-child bash "$0" --inside "$@"
fi
shift
[[ $$ == 1 ]]
root=$(realpath -e "$1"); tarfile=$(realpath -e "$2")
printf '%s  %s\n' 6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c "$root" | sha256sum --strict -c -
w=$(mktemp -d)
r=$w/root
cleanup() {
    cd /
    if mountpoint -q "$r"; then umount -R "$r" || return 1; fi
    if mountpoint -q "$w/lower"; then umount "$w/lower" || return 1; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir "$r" "$w"/{lower,upper,work}
mount -t ext4 -o loop,ro,noload "$root" "$w/lower"
mount -t overlay overlay -o "lowerdir=$w/lower,upperdir=$w/upper,workdir=$w/work" "$r"
mount -t tmpfs tmpfs "$r/run"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
mount -t tmpfs tmpfs "$r/dev"
mknod -m666 "$r/dev/null" c 1 3
mknod -m666 "$r/dev/urandom" c 1 9
ln -s /proc/self/fd "$r/dev/fd"
tar -xf "$tarfile" -C "$r/run"
o=/run/thunar-update
(cd "$r$o"; sha256sum --strict --quiet -c SHA256SUMS)
old=4.20.2-1+deb13u1
new=$old+y7001
guest() {
    chroot "$r" /usr/bin/env -i LC_ALL=C SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root "$@"
}
ledger() {
    guest dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | LC_ALL=C sort
}
run() {
    guest bash "$o/update-thunar-touch.sh" "$1" >"$w/result" 2>&1 || { cat "$w/result"; return 1; }
    grep -Fx "THUNAR_UPDATE action=$1 transaction=$2 version=$3" "$w/result"
}
reject() {
    if guest bash "$o/update-thunar-touch.sh" "$1" >"$w/result" 2>&1; then echo "Unexpected success ($2)" >&2; return 1; fi
    grep -F -- "$3" "$w/result" >/dev/null
    echo "THUNAR_REJECT reason=$2"
}
# The official Thunar package has no conffiles. Verify the system and personal
# settings remain byte-for-byte intact through upgrades and repairs.
config=$r/etc/xdg/Thunar/uca.xml
personal=$r/home/qa/.config/Thunar/uca.xml
mkdir -p "${personal%/*}" "${config%/*}"
printf '\n<!-- QA site setting -->\n' >>"$config"
printf '<actions/>\n' >"$personal"
sha256sum "$config" "$personal" > "$w/settings"
ledger >"$w/original"
run check 0 "$old"
# An ordinary competing POSIX frontend lock must reject the wrapper.
guest perl -MFcntl=:DEFAULT,:flock -e '
  sysopen(my $f, "/var/lib/dpkg/lock-frontend", O_RDWR) or die $!;
  my $lock=pack("ssx4qqix4", F_WRLCK,0,0,0,0); fcntl($f, F_SETLK, $lock) or die $!;
  open(my $ready, ">", "/run/held") or die $!; close($ready);
  select(undef,undef,undef,.05) until -f "/run/release";
' & holder=$!
for ((i=0;i<200;i++)); do [[ ! -e $r/run/held ]] || break; sleep .05; done
[[ -f $r/run/held ]]
if ! reject install active-dpkg-lock 'package manager is busy'; then touch "$r/run/release"; wait "$holder"; exit 1; fi
touch "$r/run/release"; wait "$holder"
main=$r/usr/bin/thunar
ts() { sha256sum "$r/var/lib/dpkg/status" "$r/var/log/dpkg.log"; }
before=$(ts); run rollback 0 "$old"; [[ $(ts) == "$before" ]]
candidate="$r$o/thunar_${new}_arm64.deb"
cp "$candidate" "$w/pristine.deb"; printf X >> "$candidate"
reject install corrupted-archive FAILED
[[ $(ts) == "$before" ]]; mv "$w/pristine.deb" "$candidate"
run install 1 "$new"
ledger >"$w/updated"
diff -u <(awk -F '\t' -v OFS='\t' -v v="$new" '$1=="thunar" {$2=v} {print}' "$w/original") "$w/updated"
printf 'THUNAR_LEDGER count=%d pre=%s post=%s\n' "$(wc -l < "$w/original")" \
    "$(sha256sum "$w/original" | cut -d' ' -f1)" "$(sha256sum "$w/updated" | cut -d' ' -f1)"
before=$(ts); run check 0 "$new"; run install 0 "$new"; [[ $(ts) == "$before" ]]
# Reinstall explicitly repairs the installed revision if its program was altered.
printf X >> "$main"
reject check altered-binary 'Thunar files differ'
run reinstall 1 "$new"
run rollback 1 "$old"
ledger | cmp - "$w/original"
guest dpkg --unpack "$o/thunar_${new}_arm64.deb" >"$w/unpack.log" 2>&1
reject check unpacked 'Run install or rollback'
run install 1 "$new"
guest dpkg --unpack "$o/thunar_${old}_arm64.deb" >"$w/unpack.log" 2>&1
run rollback 1 "$old"
ledger | cmp - "$w/original"
sha256sum --strict --quiet -c "$w/settings"
guest dpkg --audit > "$w/audit"; [[ ! -s $w/audit ]]
guest apt-get --no-download --simulate check >/dev/null
# Model a newer security revision only in the throwaway dpkg database.
sed -i "/^Package: thunar$/,/^$/s/^Version: .*/Version: 4.20.2-1+deb13u2/" "$r/var/lib/dpkg/status"
before=$(ts)
for action in install reinstall rollback; do reject "$action" newer-security 'Unsupported installed Thunar version'; done
[[ $(ts) == "$before" ]]
cleanup; trap - EXIT
echo 'THUNAR_LIFECYCLE_PASS root_read_only=1 interrupted_both_directions=1 settings_preserved=1'
