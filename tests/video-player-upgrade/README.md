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

From the product checkout, pass the complete retained combined Parole archive, the directory holding the stock and HiDPI Parole debs and signed Debian source archives, the candidate Iris ELF, its source patch and a new output TAR filename. The builder rejects mismatched inputs. The Parole build recipe and source archives are under `source/parole` in the transport. The original GStreamer source archives, r2 build scripts and the additional seek patch are under `source/gstreamer`.

```sh
bash tests/video-player-upgrade/build.sh \
    out/video-player-integration/y700-dev12.8-parole-iris-arm64.tar.gz \
    out/parole-touch out/video-seek/plugin-session/libgstvideo4linux2.so \
    .local/iris-session-seek.patch out/video-player-upgrade/y700-dev12.9-player-update-arm64.tar.gz
sudo bash tests/video-player-upgrade/test-overlay.sh "$DEV12_9_ROOT" \
    out/video-player-upgrade/y700-dev12.9-player-update-arm64.tar.gz
```

The PC transaction test exercises the candidate ELF with SHA-256 `1c159893127fbb4842aea2c0120be3292d6a1f32fe0596a0847417097ae7c367`. Its result covers package state, integrity checks, retry and rollback. Hardware playback and seeking are measured separately on the tablet.
