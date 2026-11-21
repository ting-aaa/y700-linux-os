# Dev12.9 offline player update

The archive contains the HiDPI Parole package, its companion private Iris seek plugin, the two original files for rollback and their source inputs. The private plugin applies only to the existing Y700 Parole launcher. A local desktop entry still opens Parole through GIO and Thunar. Debian's system GStreamer plugin and the launcher retain their original hashes.

## Install in the target system

Use the root of a disposable dev12.9 RAM desktop or a writable copy of the generic image. The installer checks the inherited media receipts, launcher, desktop entries, Debian system plugin, installed Parole files and the complete 1,240-package inventory. It accepts the sealed or candidate versions of both player components. Close any open Parole window so a subsequent launch loads the selected versions. Verify the archive against the separately trusted outer SHA-256 before extracting it.

```sh
sha256sum --check SHA256SUMS
tar -xzf y700-dev12.9-player-update-arm64.tar.gz
cd y700-player-update
bash install.sh check
sudo bash install.sh install
bash install.sh verify
```

Run `sudo bash install.sh rollback` and then `bash install.sh verify-stock` to return to the original two components. Installation and rollback use the included .deb files and require no network. Both operations can be repeated. After an interrupted update, repeat the intended command with the same trusted archive. The installer serializes changes, records an in-progress update before invoking dpkg, and publishes a verified private ELF by atomic rename. Each replacement advances the file modification time because the two ELF files have the same length and GStreamer checks timestamps. The original image receipts describe the stock pair. The update's `verify` command checks the optional child state; the stock image verifier applies again after rollback.

## Rebuild and check on a PC

From the product checkout, pass the retained combined Parole archive, the directory holding the stock and HiDPI Parole debs and verified Debian source archives, the tested Iris ELF and a new output TAR filename. The builder takes the seek patch and build script from `tests/video-vp9/` and checks their hashes.

```sh
bash tests/video-player-upgrade/build.sh \
    out/video-player-integration/y700-dev12.8-parole-iris-arm64.tar.gz \
    out/parole-touch "$TESTED_SEEK_PLUGIN" out/video-player-upgrade/y700-dev12.9-player-update-arm64.tar.gz
sudo bash tests/video-player-upgrade/test-overlay.sh "$DEV12_9_ROOT" \
    out/video-player-upgrade/y700-dev12.9-player-update-arm64.tar.gz
```

Inside a clean extracted `y700-player-update` directory, the following commands rebuild both modified components and reproduce the transport. Put build output outside the extraction. The Parole step needs Debian trixie arm64 with its build dependencies. The GStreamer step needs uv, Meson, Ninja and arm64 development libraries. The reference cross build used Meson 1.7.0, Clang 21.1.8 targeting `aarch64-linux-gnu`, GNU ld.bfd 2.46 and `STRIP=aarch64-linux-gnu-strip`. Set `MESON_PYTHON` to the installed interpreter containing Meson and pass the machine file as the last argument to `build-seek.sh` when cross-building.

```sh
work=$(mktemp -d)
bash source/parole/seek/build.sh "$PWD/source/parole" "$work/debs"
cmp "$work/debs/parole_4.18.2-1+y7002_arm64.deb" candidate/parole_4.18.2-1+y7002_arm64.deb
bash source/gstreamer/build-seek.sh "$PWD/source/gstreamer" "$work/gst" # append the machine file when cross-building
cmp "$work/gst/seek/private/libgstvideo4linux2.so" candidate/libgstvideo4linux2.so
cmp "$work/gst/color-r2/private/libgstvideo4linux2.so" stock/libgstvideo4linux2.so
bash repack.sh "$work/rebuilt.tar.gz"
cmp "$work/rebuilt.tar.gz" ../y700-dev12.9-player-update-arm64.tar.gz
```

Parole y7002 lets the slider follow a HiDPI drag and seeks once at release. Its companion Iris plugin handles a second flush during CAPTURE negotiation. If a previous trial package is installed, run that archive's `rollback` to restore the stock pair before installing this revision. The archive's `payload.sha256` identifies all four files. The PC transaction test covers package state, integrity checks, retry and rollback. Hardware playback and seeking have separate tablet receipts.
