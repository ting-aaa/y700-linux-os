# TB320FC_PRC candidate 03

Candidate 03 combines the fresh 993-package Debian ARM64 root with the previously built PRC kernel 7.3.4-asphalt-prc, modules, board DTB, firmware and EFI components. PC verification reached systemd PID 1. Physical candidate acceptance is pending. This build uses pinned prebuilt board components. Rebuilding the kernel and U-Boot from source in a clean environment remains a separate release task.

## Build on a Linux host

Use a native Linux filesystem for the build directories. Install the tools used by the [Debian snapshot build](DEBIAN-SNAPSHOT.md), plus rsync, kmod, cpio, gzip, e2fsprogs, dosfstools, mtools, util-linux (sfdisk with selectable sector size), device-tree-compiler and zstd. Obtain the pinned [Asphalt checkout](PROVENANCE.md), the integrated Debian root, and the private board components described below. Run as root on the build host with uv configured for an installed Python 3.12 or 3.13. Each output directory must be new.

```sh
bash scripts/build-board-image.sh "$ROOT" "$BOARD" "$PRC_UBOOT" "$BUILD/images"
bash scripts/build-test-card.sh "$BUILD/images" "$BUILD/card"
bash scripts/build-trial-entry.sh "$BUILD/card" "$BUILD/entry"
bash tests/board-image-vm.sh "$BUILD/images" "$BOARD" "$QEMU" "$BUILD/vm-ufs"
bash tests/board-image-vm.sh "$BUILD/images" "$BOARD" "$QEMU" "$BUILD/vm-split" "$BUILD/card" "$BUILD/entry"
uv run --no-project --python 3.12 python tests/first-login.py \
  --images "$BUILD/images" --board "$BOARD" --qemu "$QEMU" --split-vm "$BUILD/vm-split" \
  --card "$BUILD/card" --work "$BUILD/vm-login"
bash scripts/export-board-image.sh "$BUILD/images" "$BUILD/export" "$BUILD/card" "$BUILD/entry"
```

`ROOT` is the configured, integrated root produced by the snapshot instructions. `BOARD` contains the original Linux build, modules, BusyBox, board firmware and reviewed loader files. [Board file pins](../config/board-components.sha256) give exact relative paths. The builder also checks the recursive regular-file hash for modules and board firmware, the firmware symlink and the pinned upstream commit for the two ALSA profiles. `PRC_UBOOT` is the 41,406,464-byte PRC Android boot container in the table below. `QEMU` is the extracted x86-64 QEMU system bundle with usr/bin, usr/lib and usr/share. The VM test requires the pinned QEMU-virt U-Boot binary and virtual device tree under `BOARD/efi`. The build uses a fresh filesystem identity each time. The hashes below identify one specific build.

The image builder stages a separate root, omits build SSH keys and runtime state, installs the module/firmware tree, and creates an ext4 image. The generated initramfs validates the board, storage path, requested partition label, ext4 UUID and image identity before switching root. New builds include the count and digest of all package/version/architecture tuples in the checksummed `identity.txt`. The VM and physical probes use those values. Candidate 03 uses the historical receipt built into the probes. Local development accounts retain the existing console first-boot setup. Private maintenance credentials are provisioned separately. The package snapshot still needs its security refresh before release.

## Candidate files and verification

| Raw artifact | SHA-256 |
| --- | --- |
| PRC U-Boot Android container | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| UFS EFI FAT image | `c07e112287f56a8b7648365effa8338a9b46731a482b179e7e4a45f0bd2ad382` |
| 6 GiB ext4 root | `be0c44fcbc1ab22b57ce236e8b23b91b7074b95b70af4f8858edab9e73df280b` |
| 512-byte-sector GPT test-card image | `1050d221448f16f7e6ac005e885813789df2da07437237b7c2bf073acfeca593` |
| Candidate initramfs in both entries | `efa0a86d17a1759e4c246fdce596fddd9d4a28ca2fd914f4568873be8c112cb6` |

The packaged Linux DTB matched the PRC identifiers, five measured RAM banks and 38 fixed reservations. ext4 and FAT filesystem checks passed. The FAT readback matched the staged files. Reading the root partition range out of the card image reproduced every byte of the checked ext4 filesystem. The export includes raw-image and compressed-transport manifests. The vendor firmware, roots and images remain local.

The UFS-layout VM used 4096-byte sectors and reached the candidate root on `/dev/vda2`. The two-disk VM started the bootloader from the simulated internal ESP, followed the supplementary EFI entry and mounted `/dev/vdb2` as root and `/dev/vdb1` at `/boot`. Its card copy had the fallback EFI loader removed to exclude booting the wrong disk. Guest checks matched the exact filesystem UUID, candidate identity, ARM64 kernel release, 993 installed packages, clean dpkg audit and systemd PID 1. The test harness changes the virtual DT, serial/diagnostic boot options and test ESP contents on private copies. The root filesystem, Linux kernel and candidate initramfs are the delivered bytes. This covers EFI and Debian userspace in QEMU; the Qualcomm UFS/SD hardware, ABL handoff and real desktop require the tablet.

The first-login VM booted the regular graphical target with a virtual USB keyboard. A password entered twice at the candidate's first-boot console authenticated both a serial login and the LightDM graphical login as `y700`. The guest confirmed that the Xfce session, window manager, panel and desktop ran as that user. The test used private writable snapshots and generated its password in memory. The exported root retains its original hash and awaits enrollment on the tablet.

## Dev5 UFS-layout check, 2026-11-19

The tested platform archive was built with `SOURCE_DATE_EPOCH=1794969749`. Its SHA-256 is `7c1750228557e2d0a1ce0dea8466ec9e6d0085673fccd7c1597b6168d1eb799a`.

The ARM64 root with the 963-package base and 30 locked repair archives was upgraded to `y700-platform 0.1.0~dev5`. The built image `y700-prc-0c54370f-aae7-4020-957e-192dbdba9108` passed ext4 and FAT checks. Direct inspection of the ext4 image confirmed the packaged Bluetooth helper and the enablement link under `bluetooth.service.wants`. The per-device address file must be provisioned on the installed device.

The 4096-byte-sector QEMU test reached systemd PID 1 via EFI with the root on `/dev/vda2` and ESP on `/dev/vda1`. The guest verified all 994 installed package tuples against `b1231983bf8ad6a3dc39075f28f87202d3321a736b13883943024c5c613e6ae7` and reported a clean dpkg audit. The dev5 check covers the UFS-layout VM. Physical boot, the separate card workflow and Bluetooth HID acceptance have their own tests.

## Attended candidate 03 tablet gate

The U-Boot DT shipped in the current PRC container disables the SD controller at 0x8804000. The Linux DT enables it. On the running baseline, read-only inspection found the SD card behind that controller, the working default entry named `debian.conf`, about 924 MiB free on the internal ESP, and unused trial entry paths. The physical verification probe correctly rejected the old installed image. The existing card contains a partition and has no implied erase permission.

1. With the owner present, identify a **separately authorized expendable card** of at least 7,519,338,496 bytes (7171 MiB) and confirm the intended reader and card. Prepare that card on the PC and verify the written image range against the raw SHA-256. Arrange local input for the console password setup and a known recovery route before restarting.
2. Review the four files listed in the trial-entry manifest and check available ESP space, the existing default, and destination collisions again. During the authorized trial, add the three payloads under `EFI/y700-test/` and one `loader/entries/y700-test.conf` on the internal ESP. Read back all four hashes. Keep the original boot entries, U-Boot container and slot selection. The test kernel will use the uniquely identified card root and mount its corresponding FAT partition at `/boot`.
3. During the approved reboot select **Y700 candidate (microSD)** manually for this boot. At the first console prompt enter a new password for `y700` twice with a keyboard. The first-boot service waits for this before starting the display manager. Record the entry actually selected, the display, and the time to the console and graphical login.
4. The export includes `verify-physical-boot.sh`, its companion `identity.txt` and `PROBE-SHA256SUMS`. Verify them on the PC with `sha256sum -c PROBE-SHA256SUMS`. Make those two files available to the local session on separate removable media or via an independently available transfer. From that directory run `sh verify-physical-boot.sh`. The expected UUID and package receipt come from the export. Candidate 03 also accepts `sh verify-physical-boot.sh UUID` with its built-in package receipt. Capture the PASS line, kernel, root and ESP evidence. If the helper cannot yet be transferred, record `cat /etc/y700/image-id`, `findmnt /`, `findmnt /boot`, `uname -r` and `cat /proc/1/comm` at the local terminal. Continue the remaining checks before recording acceptance.
5. Return through the known internal Debian entry under supervision and verify the original image identity and maintenance channel. Remove only the four trial files after their identity is confirmed. An inability to select the trial, a black screen or loss of access ends the trial pending recovery. Candidate acceptance requires actual boot evidence and successful return to the working baseline.
