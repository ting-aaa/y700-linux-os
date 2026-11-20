#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
if (( $# != 5 )); then
    echo 'Usage: run-tablet.sh USB_SSH_WRAPPER X11_DEB_DIR DBUSMOCK_DEB ARM64_UV EXPECTED_BLUEMAN_VERSION' >&2
    exit 2
fi
version=$5
case $version in 2.4.4-1+y7001|2.4.4-1+y7002) ;; *) exit 2 ;; esac
ssh=(bash "${1:?USB SSH wrapper}")
assets=$(realpath -e "${2:?ARM64 X11 archive directory}")
mock=$(realpath -e "${3:?dbusmock archive}")
uv=$(realpath -e "${4:?ARM64 uv}")
work=$(mktemp -d /tmp/y700-blueman-live.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-blueman-live\.[a-zA-Z0-9]{8}$ ]]
stage=
remove_stage() {
    "${ssh[@]}" "test \"\$(realpath -e '$stage')\" = '$stage' && rm -r --one-file-system -- '$stage' && test ! -e '$stage'"
}
cleanup() {
    if [[ $stage =~ ^/var/tmp/y700-blueman-tablet\.[a-zA-Z0-9]{8}$ ]]; then remove_stage || true; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir -p "$work/source" "$work/send/bundle/"{bin,lib,python}
for deb in "$assets/"{xvfb,xdotool,libxdo3}_*.deb "$mock"; do dpkg-deb -x "$deb" "$work/source"; done
bundle=$work/send/bundle
install -m755 "$uv" "$bundle/uv"
install -m755 "$work/source/usr/bin/Xvfb" "$bundle/bin/"
install -m755 "$work/source/usr/bin/xdotool" "$bundle/bin/xdotool.real"
cp -L "$work/source/usr/lib/aarch64-linux-gnu/libxdo.so.3" "$bundle/lib/"
cp -a "$work/source/usr/lib/python3/dist-packages/dbusmock" "$bundle/python/"
cat > "$bundle/bin/xdotool" <<'SH'
#!/bin/sh
exec /lib/ld-linux-aarch64.so.1 --library-path "${0%/*}/../lib" "${0%/*}/xdotool.real" "$@"
SH
chmod 755 "$bundle/bin/xdotool"
install -m644 "$here/probe.py" "$bundle/"
sed -e 's|/opt/blueman-pairing|/run/blueman-pairing/tools|g' \
    -e 's|PATH=/usr/local/bin:|PATH=/run/blueman-pairing/tools/bin:/usr/local/bin:|' \
    "$here/run-session.sh" > "$bundle/run-session.sh"
install -m644 "$here/tablet-namespace.sh" "$here/tablet-check.sh" "$work/send/"
stage=$("${ssh[@]}" 'mktemp -d /var/tmp/y700-blueman-tablet.XXXXXXXX')
[[ $stage =~ ^/var/tmp/y700-blueman-tablet\.[a-zA-Z0-9]{8}$ ]]
tar -C "$work/send" -czf - . | "${ssh[@]}" "tar -C '$stage' -xzf -"
status=0
"${ssh[@]}" "bash '$stage/tablet-check.sh' '$stage' '$version'" || status=$?
remove_stage
stage=
echo 'BLUEMAN_TABLET_STAGING_CLEANUP paths_remaining=0'
exit "$status"
