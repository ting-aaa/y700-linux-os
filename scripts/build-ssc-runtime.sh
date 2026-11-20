#!/usr/bin/env bash
# Package the native SDSP listener for hardware-triggered startup on Debian ARM64.
set -euo pipefail
export LC_ALL=C
umask 022
if [[ $# != 3 || ! $2 =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Usage: build-ssc-runtime.sh FASTRPC_ARCHIVE SHA256 OUTPUT' >&2
    exit 2
fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
source_archive=$(realpath -e -- "$1")
expected_digest=$2
output=$(realpath -m -- "$3")
actual_digest=$(sha256sum "$source_archive")
[[ ${actual_digest%% *} == "$expected_digest" ]] || {
    echo 'FastRPC archive checksum differs from the supplied build receipt.' >&2
    exit 1
}

work=$(mktemp -d)
archive=
trap 'rm -rf -- "$work"; if [[ -n $archive ]]; then rm -f -- "$archive"; fi' EXIT
stage=$work/package
libdir=$stage/usr/lib/y700/ssc
programs=$stage/usr/libexec/y700-ssc
install -d "$stage/DEBIAN" "$libdir" "$programs"

# Read only the named regular files and create the installed links ourselves.
tar -xJOf "$source_archive" ./usr/sbin/sdsprpcd > "$programs/sdsprpcd"
chmod 755 "$programs/sdsprpcd"
for library in libsdsprpc libsdsp_default_listener; do
    tar -xJOf "$source_archive" "./usr/lib/aarch64-linux-gnu/$library.so.1.0.0" \
        > "$libdir/$library.so.1.0.0"
    ln -s "$library.so.1.0.0" "$libdir/$library.so.1"
    ln -s "$library.so.1.0.0" "$libdir/$library.so"
done
for file in "$programs/sdsprpcd" "$libdir"/*.so.1.0.0; do
    header=$(readelf -h "$file")
    grep -E 'Machine:[[:space:]]+AArch64' <<< "$header" >/dev/null
    dynamic=$(readelf -d "$file")
    if grep -E '\((RPATH|RUNPATH)\)' <<< "$dynamic" | grep -qE '/tmp/|/\.libs'; then
        echo "FastRPC file contains an uninstalled build search path: $(basename "$file")" >&2
        exit 1
    fi
done

unit=$repo/src/sensors/ssc
install -Dm644 "$unit/y700-ssc.service" "$stage/usr/lib/systemd/system/y700-ssc.service"
install -Dm644 "$unit/proxy.conf" "$stage/usr/lib/systemd/system/iio-sensor-proxy.service.d/90-y700-ssc.conf"
install -Dm644 "$unit/y700-ssc-device.target" "$stage/usr/lib/systemd/system/y700-ssc-device.target"
install -Dm644 "$unit/90-y700-ssc.rules" "$stage/usr/lib/udev/rules.d/90-y700-ssc.rules"
install -m755 "$unit/postinst" "$stage/DEBIAN/postinst"
install -m755 "$unit/seed" "$unit/wait-accelerometer" "$programs/"
install -m755 "$repo/scripts/import-ssc-calibration.py" "$programs/import-calibration"
license=$stage/usr/share/doc/y700-ssc-runtime/copyright
install -d "$(dirname -- "$license")"
tar -xJOf "$source_archive" ./usr/share/doc/y700-ssc-fastrpc/copyright > "$license"
printf '%s\n' "$expected_digest" > "$stage/usr/share/doc/y700-ssc-runtime/fastrpc-source-archive.sha256"

cat > "$stage/DEBIAN/control" <<'EOF'
Package: y700-ssc-runtime
Version: 0.1.3
Architecture: arm64
Maintainer: Y700 Linux OS contributors <maintainers@example.invalid>
Section: admin
Priority: optional
Depends: bash, coreutils, grep, util-linux, python3 (>= 3.11), e2fsprogs, libc6 (>= 2.38), libbsd0, libsystemd0, libyaml-0-2, systemd, udev, libssc-bin (= 0.4.4-2.1~bpo13+1.y7001), iio-sensor-proxy (= 3.9-1~bpo13+1.y7001), y700-ssc-cn350-firmware (= 17.0.350-1)
Description: Device-activated native Qualcomm SSC listener for TB320FC_PRC
 Mounts legacy DSP paths in the listener's namespace and preserves registry state.
 Starts the listener when the sensor-domain FastRPC device appears.
EOF

export SOURCE_DATE_EPOCH=1795046400
find "$stage" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
mkdir -p "$output"
filename=y700-ssc-runtime_0.1.3_arm64.deb
archive=$(mktemp "$output/.$filename.XXXXXXXX")
dpkg-deb --root-owner-group --build "$stage" "$archive"
chmod 644 "$archive"
mv -f -- "$archive" "$output/$filename"
