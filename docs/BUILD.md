# Build migration status

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
