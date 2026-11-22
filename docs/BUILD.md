# Build migration status

## Unified Full-Hardware Kernel (`hw-bringup-02`) & Standalone `dev13.0` Image

To reproduce the unified `7.3.4-asphalt-prc` kernel (GMU HFI queued-vote fix, 60/120 Hz dual refresh, `GT9768` rear AF, `PMK8350` RTC, dual `AW86927` 170 Hz LRA haptics, `PM8350C` rear flash LED, and `WCD9385` internal dual microphones) and package the standalone `dev13.0` board archive from the sealed `dev12.13` + `dev12.15` desktop base on a Linux/WSL build host:

```bash
sudo bash scripts/build-hw-bringup-kernel.sh "$PREPARED_LINUX_7_3_4" out/hw-bringup-02
sudo bash scripts/build-dev13-image.sh \
    "$DEV1213_TAR" "$DEV1215_TAR" out/hw-bringup-02 "$TX3_TPLG" out/dev13.0-board
sudo bash tests/hw-bringup/qemu-verify-dev13.sh out/dev13.0-board
```

Details, exact SHA-256 checksums, and all 9-subsystem physical verification receipts are recorded in [HARDWARE-VERIFICATION.md](HARDWARE-VERIFICATION.md) and [DEV13.0-IMAGE.md](DEV13.0-IMAGE.md).

## Optional Thunar update for the tablet desktop

The sealed dev12.15 root ships Debian's Thunar. The standalone touch update for that desktop consists of an arm64 build of the same Debian source with the Y700 input patch and its original rollback package. Build both inputs as described in the [ARM64 instructions](../tests/thunar-touch/README.md). From the product checkout, run `bash scripts/package-thunar-touch-update.sh out/thunar-touch out/thunar-touch/thunar-touch-y7001.tar`. Use the resulting bundle in the target root after its base packages are configured. [Installation and board verification](THUNAR-TOUCH.md)

## Disk budgets for image builds

The large host builders check capacity before creating their output. They reserve one build lane using an advisory lock on the existing `/var/tmp` directory inode. A concurrent guarded builder sharing that directory reports `Storage busy` and can be retried after the first job exits. Kernel release of the file descriptor also covers an interrupted build. Small package builds can continue in parallel.

| Entry point | Planned additional space |
| --- | ---: |
| `build-board-image.sh`, `build-test-card.sh` | 16 GiB |
| `update-sealed-root.sh` | 8 GiB |
| `package-board-image.sh`, `build-ram-trial.sh`, `export-board-image.sh` | 4 GiB |
| `build-camera-esp.sh`, `build-ram-receiver.sh` | 2 GiB |

Allow the listed growth plus a 2 GiB free-space floor on the destination. On WSL the guard also reads the actual free space on the Windows drive holding the distro VHDX, normally `/mnt/c`, with an 8 GiB floor. A destination on another Windows drive or tmpfs consumes only the host floor in that calculation. Set `Y700_WSL_HOST_VOLUME` to the actual mounted Windows volume if the distro was moved. Linux and host floors can be configured per invocation in MiB via `Y700_STORAGE_FLOOR_MIB` and `Y700_STORAGE_HOST_FLOOR_MIB`. These budgets estimate simultaneous files in current recipes. Unrelated processes and other WSL distros can still consume disk space.

```bash
bash scripts/build-storage-guard.sh status /var/tmp check
bash scripts/build-storage-guard.sh card /var/tmp check
```

## Keep or reclaim individual scratch products

For new jobs, create a private store on a Linux filesystem supporting `flock`, `O_TMPFILE` and file leases, such as ext4. Use one Linux identity throughout. A job command starts in its own `work` directory, also exposed through `Y700_BUILD_SCRATCH`. The store records the final exit status. A killed supervisor with no remaining job lease appears as `interrupted`.

```bash
repo=$PWD
store=/var/tmp/y700-managed-$UID
storage() { uv run --offline --no-project --python /usr/bin/python3 python "$repo/scripts/build-storage.py" "$@"; }
storage init "$store"
storage run "$store" sd13 bash "$repo/scripts/build-test-card.sh" "$images" card
storage status "$store"
storage archive "$store" sd13 card/y700-test-card.img
storage prune "$store" sd13 card/y700-test-card.img
```

Archiving independently decompresses and hashes the copy. Identical bytes share one object. The default limits are four objects, 4 GiB compressed per object and 8 GiB compressed in total, configured on a new store with `init --count N --single BYTES --total BYTES`. Capacity exhaustion keeps the original. The archive staging file is anonymous, so a terminated compressor releases the allocation when its descriptors close. These limits apply to managed archive objects. Existing releases, unmanaged build directories and unarchived scratch files keep their own lifecycle.

Pruning takes one explicit relative filename per call. It requires the job's prior archive record, the complete readable archive, matching file bytes and metadata, an idle job, an exclusive file lease and an unmounted job tree. Files with multiple hard links or extended attributes stay in place. Failed jobs support the same verification. No timer scans or removes old output. To restore the file content, decompress `$store/objects/RAW_SHA256.zst` into a new regular file and compare its SHA-256 to `RAW_SHA256`. After copying a compressed object outside the store, `storage retire "$store" RAW_SHA256 /path/to/copy.zst` rechecks its decoded bytes before releasing the managed copy. Other files in the same job remain available.

Exercise the limits, duplicate protection and concurrency with `bash tests/build-storage.sh`. On a Linux test host, `sudo env UV_BIN="$(command -v uv)" bash tests/build-storage.sh --mounts` also covers all eight build entry points and the mounted tmpfs/open loop cases in a private namespace, using disposable sparse files.

The dev12.12 build starts from the sealed PRC dev12.11 root, EFI FAT and U-Boot. Supply the platform archive identified by the desktop update lock and the verified dual-refresh kernel directory. Use new output directories on a Linux filesystem. After unpacking the completed TAR, the three card commands generate ordinary files on the host. [Release hashes](DEV12.12-VERIFICATION.md) · [Unpacking](DEV12.12-IMAGE.md) · [Per-device setup](DEV12.12-PER-UNIT.md)

```sh
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh platform-desktop-update \
    "$dev1211/root.ext4" "$desktop_packages" "$work/root"
bash scripts/build-camera-esp.sh --dev12.12 "$dev1211/linux-boot.fat" "$dual_refresh" "$work/linux-boot.fat"
bash scripts/package-board-image.sh dev12.12 "$work/root/root.ext4" \
    "$(sha256sum "$work/root/root.ext4" | cut -d' ' -f1)" "$work/linux-boot.fat" \
    "$(sha256sum "$work/linux-boot.fat" | cut -d' ' -f1)" "$dev1211/asphalt-prc-u-boot.img" "$work/release"
bash scripts/build-test-card.sh "$unpacked_dev1212" "$work/card"
bash scripts/build-trial-entry.sh "$work/card" "$work/entry"
bash scripts/export-board-image.sh --card-only "$unpacked_dev1212" "$work/export" "$work/card" "$work/entry"
```

The dev12.10 board image can be assembled from the sealed dev12.9 root and the verified ARM64 player update. The image guide covers extraction and rebuilding the RAM bundle from the distributed files. [Dev12.10 build instructions](DEV12.10-IMAGE.md)

The initial import preserves selected source recipes from the local experimental work. It is not yet a clean-checkout product image builder, and no binary release is included.

Implemented stages now include [the authenticated 962-package Debian base builder](DEBIAN-SNAPSHOT.md) and [desktop platform package/offline ARM64 integration](PLATFORM-BUILD.md). A fresh base built without copying the historical root, then passed integration with 30 authenticated repair archives and the platform package. Deterministic platform-package checks, private identity generation and actual ARM64 userspace verification are available. Kernel/firmware/image assembly remains separate. [Sensor defaults](HARDWARE-MAP.md) can also be generated from the exact pinned source without enabling hardware.

## Layout and upstream

[Candidate 03](BOARD-IMAGE.md) assembles the fresh root, initramfs, EFI filesystem and optional test-card image using pinned prebuilt board inputs. QEMU verification covers both the UFS layout and a simulated internal EFI entry loading the root from a second disk. Recompilation of the pinned board components and the actual tablet boot remain separate steps.

`reference/y700-linux/asphalt-debian/` contains kernel/PRC DT, U-Boot, initramfs, EFI and QEMU recipes. `reference/y700-linux/scripts/` and `rootfs-overlay/` contain the Debian base-root builder inputs. Their relative layout is preserved. Host-specific home-directory prefixes are normalized to `/home/builder`; these normalized copies have not rebuilt the physical images.

The pinned Asphalt source belongs at `reference/y700-linux/asphalt-upstream`. `upstream.lock.json` records the URL and exact commit. Fetch it with `bash scripts/fetch-upstream.sh` on a Linux build host; this does not access a tablet. Never silently update the pin.

The captured memory facts under the reference tree contain only memory/reservation structure. Kernel checks use five RAM banks and 38 fixed reservations for the tested configuration; do not generalize this map to another RAM variant.

## Deliberately missing inputs

- Linux and U-Boot source archives, external build tools and dependencies.
- Android mkbootimg tooling and the exact tool revisions to be made explicit during migration.
- Firmware blobs and stock/live device-tree binaries: original provenance and redistribution rights require independent review. Do not copy private backup trees into Git to satisfy these dependencies.
- Locally built base image and intermediate/artifact checksum files expected by some recipes.
- Device-specific keys, known-host records, Windows adapter configuration and live deployment scripts.

Upstream source references and relevant artifact hashes are recorded in [PROVENANCE.md](PROVENANCE.md). Absence of an input is a real migration task, not permission to remove a validation check.

## Battery indicator

The `power-desktop` board layer adds UPower and the Xfce notification-area battery indicator. Seven runtime archives come directly from the authenticated Debian package index. The power-manager binary is rebuilt from the corresponding Debian source with primary activation enabled. The board configuration supplies an Xfconf fallback for showing the icon. Debian's power-button setting and explicit user preferences retain precedence. [Power manager build](POWER-MANAGER-TOUCH.md) · [Debian input hashes](../config/power-desktop-debian-auth.lock.json) · [Complete layer](../config/power-desktop.lock.json)

Build the board configuration with `bash scripts/build-power-desktop.sh "$archives"`. In the same directory place the seven selected Debian archives and the locally built power-manager archive at the versions in the layer lock. On a Linux ARM64 or binfmt-enabled build host, run the following to make a new root from the generic dev12.6 image.

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/build-power-root.sh "$dev126_ext4" "$archives" "$new_dir"
```

## Touchscreen session lock

The optional `touch-lock` layer adds Debian's Xfce screen locker, its X11 screensaver library and the Y700 defaults for the embedded Onboard keyboard. The existing local password is checked by Debian's PAM configuration. The original dev12.5 archive predates this layer. [Debian package](https://packages.debian.org/trixie/xfce4-screensaver) · [Xfce keyboard settings](https://github.com/xfce-mirror/xfce4-screensaver/blob/xfce4-screensaver-4.18.4/src/gs-prefs.h#L113-L132)

On a Linux build host, choose an empty `lock_archives` directory. The download and configuration-package build can run as an ordinary user.

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
  --lock config/touch-lock-debian-auth.lock.json --cache "$lock_archives"
bash scripts/build-touch-lock.sh "$lock_archives"
uv run --no-project --python 3.13 python scripts/repair-inputs.py \
  verify "$lock_archives" config/touch-lock.lock.json
sudo env UV_BIN="$(command -v uv)" bash scripts/add-board-layer.sh \
  touch-lock "$disposable_arm64_root" "$lock_archives"
```

For a copy of the sealed dev12.5 root, pass `--sealed-dev12-5 --qcam-lock tests/onboard-image/camera-qcam.lock.json` before `touch-lock`. The first option selects the original platform version. The second selects the sealed camera application. After upgrading either package, omit its corresponding option. The verifier checks the installed package inventory against the selected versions.

The dev12.8 platform package adds the optional ambient-light worker and the bilingual brightness preference. Two independent builds produced the SHA-256 below. Run these commands from the dev12.8 source on Linux. [Board image assembly](ADAPTIVE-BRIGHTNESS-IMAGE.md) · [Desktop tests](BRIGHTNESS.md#automatic-brightness)

```sh
SOURCE_DATE_EPOCH=1795182000 bash scripts/build-platform.sh out/platform-dev12.8
(cd out/platform-dev12.8 && echo '95b8e4419a40080e98b78dbfe63839476c20479714ffb7257cfb7bbafc927583  y700-platform_0.1.0~dev12.8_all.deb' | sha256sum -c -)
```

The previous dev12.6 platform package requires positive confirmation from the session locker before automatic rotation can move the display. Include the touch-lock layer for Xfce desktops that use automatic rotation. To reproduce the previous package, use the dev12.6 source and its build epoch.

```sh
SOURCE_DATE_EPOCH=1795170250 bash scripts/build-platform.sh out/platform-dev12.6
cd out/platform-dev12.6
echo '651fcc5de550d9ac645b53e853693bdc751dd07bfaee1a8c75f4f84d466b04bf  y700-platform_0.1.0~dev12.6_all.deb' | sha256sum -c -
```

## First implementation milestone

1. Inventory every recipe input/output and privilege boundary. Split host build, image customization and device deployment.
2. Replace developer-specific paths and implicit host state with checked configuration; retain exact input validation.
3. Integrate all accepted live repairs into packages/overlays, including GUI dependencies, keyboard autostart, NTP, touch mapping, the USB service and the temporary GPU policy.
4. Provision fresh per-install identities/credentials; do not embed the prototype maintenance key or fixed production MAC/serial for every device.
5. Build in a clean Linux workspace, audit package dependencies, run static/DT/initramfs checks and QEMU tests, then stage an attended physical candidate with recovery.

The imported `package.sh` still contains the obsolete USB status service and historical root assembly; it must be migrated before a new candidate can claim parity with the repaired physical system. The PRC U-Boot repacker still references external device-tree captures; it is retained for provenance and must not be presented as self-contained.

For initial source checks, stage the intended public files and run:

```sh
uv run --python 3.13 --no-project python scripts/check-public-tree.py
```

This check parses Python, checks shell syntax where Bash is available, and scans tracked/staged text for obvious private content. It neither executes build recipes nor verifies physical hardware.
