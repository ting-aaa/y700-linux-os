#!/usr/bin/env bash
# Install one optional, locked archive set in an offline Debian build root.
set -euo pipefail
if (( $# != 3 )); then
    echo 'Usage: add-board-layer.sh firstboot-touch|warm-greeter|ssc DISPOSABLE_ARM64_ROOT ARCHIVES' >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
layer=$1
case $layer in firstboot-touch|warm-greeter|ssc) ;; *) echo 'Unknown board layer' >&2; exit 2 ;; esac
root=$(realpath -e -- "$2")
archives=$(realpath -e -- "$3")
lock=$repo/config/$layer.lock.json
test "$(id -u)" = 0
test "$root" != /
test -f "$root/.y700-disposable-build-root"
test ! -L "$root/.y700-disposable-build-root"
test ! -d "$root/run/systemd/system"
test "$(chroot "$root" dpkg --print-architecture)" = arm64
test -d "$root/tmp"
test ! -L "$root/tmp"
if [[ $layer == firstboot-touch ]]; then
    test -x "$root/usr/local/sbin/y700-firstboot"
    test -f "$root/etc/systemd/system/y700-firstboot.service"
fi
py=("${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.13}" python)
stage=$(mktemp -d "$root/tmp/y700-board-layer.XXXXXXXX")
policy=$root/usr/sbin/policy-rc.d
cleanup() {
    if [[ $stage/no-service-starts -ef $policy ]]; then rm -f -- "$policy"; fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
cp -- "$archives/"*.deb "$stage/"
"${py[@]}" "$repo/scripts/repair-inputs.py" verify "$stage" "$lock"
debs=()
for path in "$stage/"*.deb; do debs+=("${path#"$root"}"); done
printf '#!/bin/sh\nexit 101\n' > "$stage/no-service-starts"
chmod 755 "$stage/no-service-starts"
# The hard link claims the path exclusively, including against a dangling symlink.
ln -- "$stage/no-service-starts" "$policy"
chroot "$root" env SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"
chroot "$root" apt-get check
test -z "$(chroot "$root" dpkg --audit)"
case $layer in
    firstboot-touch)
        test -x "$root/usr/libexec/y700-firstboot/with-keyboard"
        test -x "$root/usr/libexec/y700-firstboot/buffyboard"
        ;;
    warm-greeter)
        test -s "$root/usr/share/xgreeters/arctica-greeter.desktop"
        selection=$(chroot "$root" /usr/sbin/lightdm --show-config 2>&1)
        grep -Fq 'greeter-session=arctica-greeter' <<< "$selection"
        ;;
    ssc)
        test -x "$root/usr/libexec/y700-ssc/sdsprpcd"
        test -s "$root/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc/slpi.mdt"
        test ! -L "$root/etc/systemd/system/multi-user.target.wants/y700-ssc.service"
        ;;
esac
record=$root/var/lib/y700/build
install -d "$record"
install -m644 "$lock" "$stage/$layer.lock.json"
mv -T -- "$stage/$layer.lock.json" "$record/$layer.lock.json"
chroot "$root" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$stage/packages.tsv"
mv -T -- "$stage/packages.tsv" "$record/packages.tsv"
"${py[@]}" "$repo/scripts/verify-image-packages.py" "$root"
