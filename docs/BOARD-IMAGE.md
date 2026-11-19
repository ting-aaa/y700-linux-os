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

The standard four-argument build uses the pinned original PRC kernel. To assemble a private image with the GPU queue fix, append `--gmu-queue-kernel "$kernel_build"` to that build command. This selects the independently built `Image` and checks its ELF notes against the [kernel input hashes](../config/gmu-queue-kernel.sha256). The companion GPU build applies `asphalt-hfi-match-queued-vote.patch` (SHA-256 `3a30e92a15e858e2238ded2e3cf7e12e462f503be2e50cef967fc87bd9f730fe`) to the checked PRC sources and compares the configuration, kernel release and exported module symbols with the baseline. Both builds use the same release string. The VM and physical checks compare `/sys/kernel/notes` for images selecting this candidate. The separate tablet GPU run with the exact kernel completed 1,800.26 seconds of FD730 OpenGL work. That run used the previous installed root filesystem.

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

## Combined tablet development image

This private build uses the queue-fix kernel, dev6 platform package, camera runtime, CN350 SSC firmware and listener, framebuffer enrollment keyboard, and Arctica greeter. The desktop account starts locked. Initial enrollment uses the local password flow. Each tablet needs its own Bluetooth address and maintenance credentials.

```sh
bash scripts/integrate-rootfs.sh "$ROOT" "$REPAIR" "$PLATFORM" "$CAMERA_DEBS"
bash scripts/add-board-layer.sh firstboot-touch "$ROOT" "$ENROLLMENT_DEBS"
bash scripts/add-board-layer.sh ssc "$ROOT" "$SSC_DEBS"
bash scripts/add-board-layer.sh warm-greeter "$ROOT" "$GREETER_DEBS"
bash scripts/build-board-image.sh "$ROOT" "$BOARD" "$PRC_UBOOT" "$DEST" --gmu-queue-kernel "$GPU_BUILD"
bash tests/board-image-vm.sh "$DEST" "$BOARD" "$QEMU" "$NEW_VM_DIRECTORY"
```

`ROOT` is a disposable, configured ARM64 build root. The archive directories contain only the locked Debian and board-specific packages for their layer. The 1,050 installed package/version/architecture tuples have SHA-256 `678305b67362a95128af32e67af11e1cce0da48f119729219e46d20c169f6602`. The dev6 platform archive SHA-256 is `3798581f2b8e12158385c1712d38620c74db69e0830f7e2953e5cd4eabee54c2` with `SOURCE_DATE_EPOCH=1794969749`. This build contains private board firmware. Tablet boot, sensor readings, and sustained workloads on this particular root filesystem require physical testing.

The resulting image ID is `y700-prc-5a984d0e-d1eb-4760-9120-1115d9ac41b5`. Readback from ext4 verified the matching CN350 SLPI metadata, camera runtime, enrollment keyboard, greeter configuration, Bluetooth helper and SSC listener. Readback from FAT matched the selected kernel. The 4 KiB-sector ARM64 EFI guest reached systemd with `/dev/vda2` as root and `/dev/vda1` as ESP. It verified the actual kernel notes and all 1,050 package tuples.

Readback of the actual FAT entry also confirmed the default console framebuffer configuration. The two 30-minute hardware GPU tests used the same kernel with the additional boot option `drm_kms_helper.fbdev_emulation=0` on a previously enrolled installation. The combined image's first-boot keyboard uses `/dev/fb0`. With the default entry, the same EFI guest completed first password setup, authenticated Xfce login and logout back to the keyboard. The GPU results and the guest login results cover different boot configurations. [Touch login evidence](WARM-GREETER.md)

| Combined image artifact | SHA-256 |
| --- | --- |
| `root.ext4` | `9d8b4f486a94e4fc28aabeaa0842eb77e1ae533a95a9b6203be44a290929ee55` |
| `linux-boot.fat` | `4e8212be559b57e94daad71a192f0bc87dde67730aaf96563ad3a6059d9f9831` |
| `asphalt-prc-u-boot.img` | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| `identity.txt` | `c29f005148c77f784e699d0074a2340a7b869bec231cc162f5a0852c95c31140` |

## KMS touchscreen build

To build for the framebuffer setting used in the long Adreno trials, begin with the integrated root containing the camera runtime, framebuffer keyboard, SSC stack and warm greeter. Apply the qcam and DRM enrollment packages, then select the KMS profile explicitly. The builder checks the enrollment receipt and helper before creating the output directory. Its EFI entry passes `drm_kms_helper.fbdev_emulation=0` to the selected queue-fix kernel.

```sh
bash scripts/add-board-layer.sh camera-qcam "$ROOT" "$QCAM_DEBS"
bash scripts/add-board-layer.sh firstboot-drm "$ROOT" "$DRM_ENROLLMENT_DEB"
bash scripts/build-board-image.sh "$ROOT" "$BOARD" "$PRC_UBOOT" "$DEST" \
  --gmu-queue-kernel "$GPU_BUILD" --kms-enrollment
bash tests/board-image-vm.sh "$DEST" "$BOARD" "$QEMU" "$NEW_VM_DIRECTORY"
```

`QCAM_DEBS` and `DRM_ENROLLMENT_DEB` are directories of locked archives. The EFI guest verifier checks the live fbdev parameter and absence of `/dev/fb0`. A read-only check on the tablet selected the integrated 1600×2560 DSI panel on `/dev/dri/card1`, DRM connector 36, while DisplayPort was disconnected. Taking over this physical display, using the touchscreen to enroll and handing the panel to the login manager require a physical boot of the KMS image.

Image `y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f` booted in the ARM64 EFI test with systemd PID 1, root on `/dev/vda2` and ESP on `/dev/vda1`. The running kernel notes matched the Adreno candidate. The guest reported fbdev emulation disabled and no framebuffer device. The 1,069 installed package/version/architecture tuples matched SHA-256 `ccb8ce6783262f6fe0bc5a159a3d71ef8a37d1c6bc0962da1fc466e794ab8bef`. The [DRM enrollment](FIRSTBOOT-DRM.md), [camera app](QCAM.md), private SSC firmware and existing warm greeter are included.

| KMS image artifact | SHA-256 |
| --- | --- |
| `root.ext4` | `7936f7c964628ef816bc1ac64aff47dcd9ae61f23bfcbd06f0649e04e8de412f` |
| `linux-boot.fat` | `9c7dbadfe9dca55f6a5da34d564a6004a99f90ad403d1323ec6bf561ec196a22` |
| `asphalt-prc-u-boot.img` | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| `identity.txt` | `2c4c34193f039e0061a2fb7156a913d65bf0b0d90eb81b32c89d3505ecc0d74b` |

A second snapshot of these delivered files reached the normal graphical target. The factory account remained locked after a confirmation mismatch. Retrying through the DRM touch keyboard, signing in to Xfce with the same password, then using Xfce's logout dialog returned to Arctica and Onboard. The four file hashes matched again after shutdown. [Full first-boot evidence](FIRSTBOOT-DRM.md)

## Optional desktop camera layers

In a disposable copy of the KMS root upgraded to platform dev7, the `camera-pipewire` layer added one ARM64 plugin for the three physical sensors. The `camera-portal` layer added 26 Debian packages for application permission requests. The resulting inventory contained 1,096 packages with package/version/architecture digest `af3c9d2b39d671aab8b293284447ee0f68a5086e16687ac45f4dcf8781b68915`. Removing the layers restored the dev7 starting inventory. The derivative also booted in ARM64 QEMU using the KMS EFI kernel and initrd. It reached systemd on kernel `7.3.4-asphalt-prc`, mounted the root from `/dev/vda2` and ESP from `/dev/vda1`, reported fbdev emulation disabled and verified the 1,096-package digest and the private camera plugin's dynamic links. The dependent QCOW2 root is 92,471,296 bytes with SHA-256 `d6d1c16984cb60841848fc7291810f6df99ba146f8cd6957efb975aaff936d0a`. Its backing file is the exact dev6 `root.ext4` in the table above. It retains that root's UUID to satisfy the EFI initrd. Use one root with this UUID at a time. Camera capture and browser permissions were exercised on the existing physical Debian installation upgraded to dev7 and the same camera packages. Cold-boot and first-enrollment acceptance of the derivative on the tablet remain open. [Layer commands and archive locks](CAMERA-PIPEWIRE.md#add-the-two-image-layers)

### Standalone dev7 camera image

The local `combined-kms-dev7-camera` bundle contains all three complete partition images. The compressed payloads occupy about 1.13 GiB together. The root's logical bytes match the EFI-tested dev7 derivative, and its FAT and PRC U-Boot match the verified KMS boot components. The bundled `identity.txt` carries the 1,096-package count and digest for use with the existing board image tools.

| Partition | Zstandard bytes | SHA-256 of the decompressed partition |
| --- | ---: | --- |
| `root.ext4` | 1,153,039,047 | `52b9c1526ad428c7f0cce336d6b5f598f945485341b5879ec4d25f4f1fe60aa0` |
| `linux-boot.fat` | 56,247,701 | `9c7dbadfe9dca55f6a5da34d564a6004a99f90ad403d1323ec6bf561ec196a22` |
| `asphalt-prc-u-boot.img` | 586,909 | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |

From the bundle directory on a PC with Bash and Zstandard, use `bash unpack.sh --verify` for a full streaming readback. Running `bash unpack.sh /path/to/new-directory` writes three raw images, the identity file and raw `SHA256SUMS` into a new directory. An end-to-end unpack of the delivered bundle into an empty Linux tmpfs verified each raw hash, all five ext4 checks, the FAT filesystem and the root UUID. The three sparse output files used 3,499,835,392 bytes there. The bundle contains the local board firmware for the tested PRC variant. [Unpack helper](../scripts/unpack-kms-image.sh)

### Standalone dev7 image with SSC 0.1.1

The private `out/combined-kms-dev7-camera-ssc-0.1.1` bundle adds the updated SSC runtime to the dev7 camera image. The only changed package tuple is `y700-ssc-runtime` version 0.1.1. The 1,096-package digest is `de52b3ddbb2bdc7995e1b9a179ddad8a31edfa1b4e7f4ab7183652add30ef6dd`. The writable SSC state starts empty. The earlier camera bundle remains available as a separate build.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `root.ext4.zst` | 1,153,777,594 | `30a86acced366df02f80bc9ce9e0afecb3d4fb34278c596c4dc9281b05a23707` |
| `root.ext4` after decompression | 6,442,450,944 | `59549a5d99990971f7368a3922982fbbaad4e3588983d8b7c55c6dac4fc0a0e8` |
| `identity.txt` | 304 | `8e8aebad82c828b68de9d5fbac049f0ec1ada9a347840c4c5d9d43de39f06918` |

The bundle occupies about 1.13 GiB. Full streaming readback verified the calculated root hash and the KMS FAT and PRC U-Boot hashes above. Use the same `unpack.sh` commands. The incremental QCOW2 in `out/ssc-calibrated-image` is 11,993,088 bytes with SHA-256 `a9d21ad32d9be39d2a8c6649a51fa1b590de42e57ab3149625f89e87c8511a80`. It uses the camera QCOW2 and dev6 `root.ext4` as backing files.

The exact source root booted with the KMS kernel and initrd to ARM64 systemd and verified the calibration importer, kernel and 1,096-package digest. The EFI guest ran the installed SSC pre-start command twice. Without a factory partition, initialization copied 329 generic configuration groups. Repeating the command preserved the existing registry and a synthetic calibration receipt byte for byte. Physical qualification covers factory import and live sensor behavior separately. [Sensor runtime](CAMERA-SENSORS.md#physical-ssc-qualification)

### Dev8 first-login keyboard image

The exact 1,096-package dev8 root booted through ARM64 EFI to the ordinary graphical target. A two-slot Linux evdev touchscreen fixture entered mismatched passwords and confirmed the account stayed locked, then entered a matching password twice. Debian PAM accepted the enrolled password and rejected another. Touching the embedded Onboard keyboard in LightDM logged in to a real Xfce session. Tapping an empty GTK text field made the desktop keyboard visible automatically, and closing the form hid it. Two further taps selected and confirmed Log Out, returning to the authenticated greeter. These inputs came from a virtual digitizer. Touch contact on the physical panel during enrollment remains to be checked.

The private `out/combined-kms-dev8-camera-ssc` folder contains everything needed to reconstruct the dev8 image on a Linux PC. It includes the compressed dev7 camera and SSC base, a 13,107,200-byte QCOW2 update and the normal Debian platform package. In the build workspace, the large compressed files share storage with the previous bundle through hard links. Copying the whole folder to a new drive includes every input.

On a PC with Bash, Zstandard, GNU coreutils and `qemu-img`, run `bash unpack.sh --verify` to check the input archives. Run `bash unpack.sh /path/to/new-directory` to produce the updated raw root, FAT and U-Boot files. Allow 7.07 GiB for the unpack destination. The unpacker applies the overlay to its own freshly extracted root and checks all output hashes before publishing the directory. The delivery was reconstructed on an empty compressed Btrfs volume and checked with `e2fsck -fn` and `fsck.fat -n`. A separate read-only export of the original build produced the same complete root hash. [Image unpacker](../scripts/unpack-kms-update.sh)

| Item | SHA-256 |
| --- | --- |
| Distribution `SHA256SUMS` | `f0274d21a5dfaa16cedde694385aa01726dfe8b3ca792561fbba9b6bbe4dafae` |
| Portable `dev8.qcow2` | `458647bd54b19fd906cc373296f408afe552f83588a3f5aa71f840f89ecdb9a3` |
| Reconstructed 6 GiB `root.ext4` | `7885957379313847570527cdc94cdd8c2423486169f3efc082cf595053062efe` |
| `y700-platform_0.1.0~dev8_all.deb` | `840bf029136b287b0f71de2f216603855f10337c999af32d1097ed796e478bac` |

The platform package introduces the first-login Onboard settings. Its version is the sole change to the 1,096 installed package tuples, whose digest is `a56e81398dfe8185974b64e3ecc19aad6d6bce6f762be5d7470db2707dd8fb83`. The private archive can also upgrade a running dev7 installation through APT. An attended boot of this exact image on the physical tablet remains open. [Platform package](PLATFORM-BUILD.md)

### Dev9 tablet scale image

The dev9 package supplies the 200% GTK scale default when Xfce starts with the internal Y700 panel as the sole active display. Saved per-user scale settings take precedence. An isolated ARM64 guest installed the reviewed dev9 package into a private copy of the dev8 root. APT and dpkg checks passed. The `y700-platform` version was the only change among all 1,096 installed package tuples. Their digest is `386ae3b92f48eda3e63ceaf95827e12721be2cd3275782d448557da8ede3baa2`.

The private `out/combined-kms-dev9-camera-ssc` bundle combines the dev8 and dev9 changes into a single QCOW2 update against the compressed dev7 camera and SSC base. The compressed base files share storage with the earlier bundles through hard links. Copy the entire folder when moving it to another drive. On Linux, run `bash unpack.sh --verify`, then `bash unpack.sh /path/to/new-directory` to reconstruct the complete image. Allow 7.08 GiB at the destination. The source unpacker accepts both dev8 and dev9 bundles. [Image unpacker](../scripts/unpack-kms-update.sh)

| Dev9 artifact | SHA-256 |
| --- | --- |
| Distribution `SHA256SUMS` | `0e1442701478a79d20168431fc19cdc4d0d68c2527e96785cbdce248e2557f7b` |
| Portable `dev9.qcow2`, 21,430,272 bytes | `edaff46682a8fe13731be53b94b7fdf1f2609cb9aad1c0b3c8e9d2915968bef2` |
| Reconstructed 6 GiB `root.ext4` | `6dcf6a9e1d792fd34d12cef9e1bfa9c3467317203862c7a8f676a49d66cd58cf` |
| `y700-platform_0.1.0~dev9_all.deb` | `a1e1fa923877ecbc60963814bed6811bf3544c05f9fdab7fb5689c976f57d0e4` |

An independent read-only NBD view of the upgraded root supplied the advertised hash and passed `e2fsck -fn`. Extraction into a fresh compressed Btrfs volume reproduced the advertised hashes for the root, FAT boot filesystem, U-Boot and identity file. Both `e2fsck -fn` and `fsck.fat -n` passed. The unpacker also rejected a corrupt overlay, a mixed dev8/dev9 manifest, an existing output directory and insufficient free space. Booting the extracted dev9 image on the physical tablet remains a separate qualification step.

### Dev9 image with the scaled qcam chooser

The private `out/combined-kms-dev9-camera2-ssc` variant contains the 200% Xfce platform package and `y700-camera-qcam 0.7.2-1~bpo13+1.y7002`. A native ARM64 package transaction upgraded only qcam on a copy of the dev9 root. The image still has 1,096 installed package tuples. The qcam lock receipt and package manifest were refreshed and independently read back from the raw root. The build verified the locked first-boot account, empty machine ID and unseeded SSC registry. The packaged EFI FAT and U-Boot bytes match the preceding dev9 bundle. [Camera app and scale validation](QCAM.md)

The bundle uses the same hard-linked compressed dev7 base and includes both standalone upgrade packages. Run `bash unpack.sh --verify` and `bash unpack.sh /path/to/new-directory` on Linux. Allow 7.09 GiB at the destination. [Image unpacker](../scripts/unpack-kms-update.sh)

To provision one tablet before first boot, prepare its private Bluetooth address file from its own stock Android identity and install `e2fsprogs` on the Linux extraction host. Use a single regular file owned by the invoking user with mode `0600` or `0400`. [Prepare the per-tablet address](PERIPHERALS.md#prepare-a-fresh-installation)

```sh
bash unpack.sh --bluetooth-address "$PRIVATE_ADDRESS_FILE" /path/to/new-private-directory
```

Extraction verifies the generic image before provisioning `/etc/y700/bluetooth-address` as `root:root` with mode `0600` in the new root. Existing identity files are rejected. `SHA256SUMS` verifies the local extracted files and `UNPERSONALIZED-SHA256SUMS` preserves the original raw manifest. Keep the address file and personalized root private. The default extraction command still produces the generic root.

A full reconstruction of this bundle on Linux with a synthetic address passed independent ext4 metadata, content and filesystem checks. The original manifest, FAT, U-Boot and identity file verified byte for byte. [Unpacker regression](../tests/unpack-kms-bluetooth.sh)

| Dev9 with qcam y7002 artifact | SHA-256 |
| --- | --- |
| Distribution `SHA256SUMS` | `1975160678f175fb3d46277fa6c604fb90a2d59bebee0d3f1a16be1899f0462f` |
| Portable `dev9.qcow2`, 28,639,232 bytes | `4cc88353aa159162a2388692f410cc00054b4652a4c8ddeca8ecb388a16f938a` |
| Reconstructed 6 GiB `root.ext4` | `b7312d29131acdd1eba42168867d50d7f344e184e610322c9c8b57e6b451c901` |
| Installed package tuples | `31bb6435b756ea88cdc9254a71675b99a2d75dd6f7d658f057971a6311380491` |

Fresh extraction into an empty compressed Btrfs volume reproduced all raw hashes. The rebuilt ext4 and FAT filesystems passed read-only checks. The rebuilt qcam lock and package manifest matched the independent NBD readback. The unpacker accepted the prior dev8 and dev9 manifest layouts and rejected a corrupt or mismatched qcam archive. The physical package upgrade is recorded separately from this image reconstruction. [Qcam package results](QCAM.md#verification)

An isolated ARM64 QEMU guest booted a disposable snapshot of the verified root. Its read-only backing bytes matched the reconstructed `root.ext4` SHA-256 above. QEMU's U-Boot loaded `BOOTAA64.EFI` from a copy of the packaged FAT with a virtual device tree and a test observer. The EFI loader, kernel and initramfs matched the packaged files byte for byte. Linux `7.3.4-asphalt-prc` started systemd as PID 1 with the ext4 root on `/dev/vda2` and the EFI partition on `/dev/vda1`. The running guest reported dev9, qcam y7002 and the expected digest for all 1,096 installed package tuples.

With framebuffer emulation disabled and `/dev/fb0` absent, the packaged KMS first-boot screen accepted virtual touchscreen input. Mismatched password entries kept the account locked. Matching entries enrolled `y700`, and PAM accepted the enrolled password and rejected an incorrect one. Touch input through the Arctica login keyboard opened an active X11 Xfce session under LightDM. The guest reached `graphical.target`, returned to the greeter after a touch logout, then powered off cleanly. The private logs and checksums are in `out/dev9-qcam2-efi-verified/`. The exact image still awaits a physical tablet boot.

### Dev9 image with the Bluetooth keyboard fix

The private `out/combined-kms-dev9-bluetooth` bundle adds Blueman `2.4.4-1+y7001` to the dev9/qcam y7002 image. A native ARM64 transaction updated just that package. It retained the locked initial account, empty per-unit Bluetooth identity and SSC state. The build verifies the original Debian package version, the local replacement archive and all 1,096 installed tuples. The exact generic root booted through ARM64 EFI, completed touchscreen password enrollment and normal LightDM login into Xfce, returned to the greeter on logout, and shut down. Physical boot of this complete image remains open. [Blueman fix and UI checks](BLUEMAN-PAIRING.md) · [Bluetooth input and reconnect](BLUETOOTH-VIRTUAL.md)

| Dev9 Bluetooth build | SHA-256 |
| --- | --- |
| Distribution `SHA256SUMS` | `1cfb405a35e6d8f35e01e024fe2c3ec61fda92e6349eed2e84b93cb15c24ad71` |
| Portable `dev9.qcow2`, 57,868,288 bytes | `27f5744161089dfd289acafd07f800e70c6a96cd75798623a4bcc50ff51b7973` |
| Generic 6 GiB `root.ext4` | `1a8e1e59784c6a49af077734f6faf4b650fee946528829b97d3acdd5f912d74a` |
| Installed package tuples | `30d7528eec91092312056cc02170fdf74b009749291827e3e767d3427be8f1c5` |

Use the included `prepare-bluetooth-identity.py` and `unpack.sh --bluetooth-address PRIVATE_FILE NEW_DIRECTORY` to provision one tablet while extracting the image. To rebuild this package layer, provide only the reviewed local Blueman archive in a directory and run `bash scripts/add-board-layer.sh blueman "$root" "$blueman_archives"` in the disposable ARM64 build environment. The public source lock identifies the authenticated Debian parent and versioned replacement. [Prepare the address](PERIPHERALS.md#prepare-a-fresh-installation) · [Package lock](../config/blueman.lock.json)

### Dev9 image with Chinese input

The local `out/combined-kms-dev9-pinyin` bundle includes 1,112 installed packages. It combines the dev9 desktop, qcam y7002, Blueman y7001, the existing board kernel and SSC firmware with the Debian IBus stack and the Y700 display language selector. A native ARM64 build added the 15 Debian packages and one board package to a disposable root. The original account is locked for first enrollment. The generic filesystem has an empty machine ID and carries no per-tablet Bluetooth address or sensor registry. [Input layer lock](../config/chinese-ime.lock.json) · [Chinese input](CHINESE-INPUT.md)

| File or receipt | SHA-256 |
| --- | --- |
| Distribution `SHA256SUMS` | `da2f4eb0553d225aef1459e93f04b58eee039c10039398ba5ffd06ef8967c7fb` |
| Portable `dev9.qcow2` (319,356,928 bytes) | `76f27dddfa4cd43d67b37de51c6ec16ac67aa2ae06db6bae37057de6bc630a75` |
| Generic 6 GiB `root.ext4` | `08a42daf79b0742a9d01c4e750b914d3886c60b08e5adfc51c6692ec9ef65a73` |
| Installed package tuples | `6e926f63e7b509e796837b986971cbeea07723ad2322a516d2da945c57a491c9` |
| Offline IME archives and their checksums (`chinese-ime.tar`) | `00ddd93a50a35563753cd0e89f7439f24065040c8010f4525cde1fe1b3135135` |

Copy the complete bundle including `base/`. On Linux, check `sha256sum --strict -c TOOLS-SHA256SUMS` and run `bash unpack.sh --verify`, then `bash unpack.sh /absolute/path/to/new-directory`. Allow 7.5 GiB of free space on the destination filesystem. The same unpacker supports the private original-address option documented above. [Prepare one tablet’s Bluetooth identity](PERIPHERALS.md#prepare-a-fresh-installation)

Two independent read-only streams of the 6 GiB filesystem matched the generic SHA-256 above. Full extraction from the portable bundle reproduced all partition hashes and the 1,112-package identity. The generic ext4 and FAT passed filesystem checks. A second full extraction with the original Android Bluetooth identity produced a root-owned 0600 address file, retained the generic hash manifest, matched the privately supplied address on readback and passed ext4 checks.

A full-system ARM64 guest booted the same generic root through EFI. The ordinary user set a password on the KMS enrollment keyboard and signed in through LightDM. From the English Xfce session the user selected Simplified Chinese. After logout a separate ordinary LightDM session inherited `LANG=zh_CN.UTF-8` and `LANGUAGE=zh_CN:zh`, and the standard GTK Cancel button displayed `取消(C)`. The system-wide default remained English. [Language selection and reproduction](DEBIAN-SNAPSHOT.md#optional-simplified-chinese-input)

### Dev10 touch mapping

The local `out/combined-kms-dev10-touch` bundle updates `y700-platform` from dev9 to `0.1.0~dev10` on the 1,112-package Chinese-input image. A full ARM64 package database comparison found exactly one changed version. The image retains the KMS boot components, qcam y7002, Blueman y7001, SSC runtime and per-user language support. The development build used `SOURCE_DATE_EPOCH=1795046400` for the platform archive. [Touch regression](../tests/display-touch-topology/README.md) · [Four-way gesture tests](TOUCH-GESTURES.md)

| File or receipt | SHA-256 |
| --- | --- |
| Distribution `SHA256SUMS` | `9faa0b12280184338903afb1441e3bde05b936dea097a22848d293824dbb9250` |
| Portable `dev10.qcow2` (326,041,600 bytes) | `2415356acdfbc0396a59eb831c88be136f669f5f39e80b0ed184ff4f11d33d2e` |
| Generic 6 GiB `root.ext4` | `48c468f461dabfd4e262614776a5997ebe8cb3ecd8834d49860c01968fd8f55e` |
| Installed package tuples | `14bdfb7ef19baf5ea6c58cdf3d307fb385eeca368f1ac01bddb5210353d61fc8` |
| `y700-platform_0.1.0~dev10_all.deb` | `8a670313ed52c48f7615b415246757fa069cd99527c65c0a16309ac56f884233` |

On Linux, copy the bundle together with `base/`. Run `sha256sum --strict -c TOOLS-SHA256SUMS`, then `bash unpack.sh --verify` and `bash unpack.sh /absolute/path/to/fresh-directory`. Allow 7.5 GiB at the destination. Full generic extraction reproduced the partition hashes and the installed display helper byte for byte. The ext4 root and FAT passed filesystem checks. A second extraction using the tablet's original Bluetooth address passed private readback and retained the unpersonalized checksums. [Per-tablet identity option](PERIPHERALS.md#prepare-a-fresh-installation)

A one-package update installed dev10 on the existing physical tablet. The new helper runs with the signed-in user's X authority and holds its singleton lock. A transient service tied to that X11 login replaced its background watcher until logout. Future graphical logins start the package's ordinary Xfce autostart. The boot, session, display mode, touch matrix, LightDM, network, SSH and Bluetooth service invocations matched before and after the change. Physical boot of the combined image remains open.

This generic root also booted through U-Boot and ARM64 EFI on the board kernel in QEMU. A locked account completed the KMS touchscreen password flow and two ordinary LightDM logins. The user selected Simplified Chinese in the first English desktop, and the second session displayed the translated GTK Cancel button before a normal poweroff. The guest recomputed all 1,112 package tuples. A separate VM using the same sealed root passed all 12 Chromium virtual direct-touch checks through the installed rotation helper and a test DSI connector. [Language observer](../tests/display-language/README.md) · [Gesture measurements](TOUCH-GESTURES.md)

## Attended candidate 03 tablet gate

The U-Boot DT shipped in the current PRC container disables the SD controller at 0x8804000. The Linux DT enables it. On the running baseline, read-only inspection found the SD card behind that controller, the working default entry named `debian.conf`, about 924 MiB free on the internal ESP, and unused trial entry paths. The physical verification probe correctly rejected the old installed image. The existing card contains a partition and has no implied erase permission.

1. With the owner present, identify a **separately authorized expendable card** of at least 7,519,338,496 bytes (7171 MiB) and confirm the intended reader and card. Prepare that card on the PC and verify the written image range against the raw SHA-256. Arrange local input for the console password setup and a known recovery route before restarting.
2. Review the four files listed in the trial-entry manifest and check available ESP space, the existing default, and destination collisions again. During the authorized trial, add the three payloads under `EFI/y700-test/` and one `loader/entries/y700-test.conf` on the internal ESP. Read back all four hashes. Keep the original boot entries, U-Boot container and slot selection. The test kernel will use the uniquely identified card root and mount its corresponding FAT partition at `/boot`.
3. During the approved reboot select **Y700 candidate (microSD)** manually for this boot. At the first console prompt enter a new password for `y700` twice with a keyboard. The first-boot service waits for this before starting the display manager. Record the entry actually selected, the display, and the time to the console and graphical login.
4. The export includes `verify-physical-boot.sh`, its companion `identity.txt` and `PROBE-SHA256SUMS`. Verify them on the PC with `sha256sum -c PROBE-SHA256SUMS`. Make those two files available to the local session on separate removable media or via an independently available transfer. From that directory run `sh verify-physical-boot.sh`. The expected UUID and package receipt come from the export. Candidate 03 also accepts `sh verify-physical-boot.sh UUID` with its built-in package receipt. Capture the PASS line, kernel, root and ESP evidence. If the helper cannot yet be transferred, record `cat /etc/y700/image-id`, `findmnt /`, `findmnt /boot`, `uname -r` and `cat /proc/1/comm` at the local terminal. Continue the remaining checks before recording acceptance.
5. Return through the known internal Debian entry under supervision and verify the original image identity and maintenance channel. Remove only the four trial files after their identity is confirmed. An inability to select the trial, a black screen or loss of access ends the trial pending recovery. Candidate acceptance requires actual boot evidence and successful return to the working baseline.
