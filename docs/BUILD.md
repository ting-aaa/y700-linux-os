# Build migration status

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
