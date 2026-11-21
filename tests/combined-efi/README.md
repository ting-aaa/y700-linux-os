# Y700 EFI desktop acceptance

Run on a Linux PC with AArch64 QEMU, the NBDKit split plugin, nbdfuse and FUSE, mtools, sfdisk, cpio, gzip, uv, and a compiler that builds static AArch64 executables. Provide a freshly reconstructed 6 GiB combined ext4 root, its 1 GiB boot FAT, and their recorded SHA-256 values. Use the project's QEMU-virt U-Boot binary and QEMU-virt device tree. The final argument is a new log directory.

```sh
IW_ARM64=./iw-extracted/usr/sbin/iw bash tests/combined-efi/run.sh \
    "$root" "$root_sha" "$esp" "$esp_sha" "$virt_uboot" "$virt_dtb" ./combined-efi-logs
```

The regulatory test uses the executable extracted from the Debian ARM64 `iw 6.9-1+b1` package. It verifies the signed pair inside the input initramfs, the upstream-signed pair selected on the root, and a radio-free global `CN` result for a hint passed only to this VM. `VERIFY_REGDB=0` selects the historical pre-regdb image path. Host tool overrides are `NBDKIT`, `NBDKIT_SPLIT`, `NBDFUSE`, `QEMU_SYSTEM_AARCH64`, `QEMU_DATA`, `QEMU_LIB`, `AARCH64_CC`, and `UV_BIN`.

The runner exports a read-only disk from four segments, leaving the original root and boot FAT untouched. The new GPT and copied ESP live in private scratch. The copy retains the original EFI loader, kernel and initramfs. It adds the virtual device tree, serial console, a command-line systemd observer, and the synthetic Type-B input device. Virtual U-Boot starts the actual EFI loader. All guest writes go into QEMU's disposable snapshot.

The host generates a throwaway password in memory and enters it through the real first-boot keyboard. It deliberately mismatches the first pair and checks that the account remains locked, then uses the matching pair for enrollment and a normal LightDM login. The controller checks pixel masks at the virtual Arctica prompts and discards each frame immediately. Neither passwords nor screenshots are stored. The guest independently checks EFI, the booted package inventory, the active ordinary Xfce session, Onboard autostart and the panel's mapped volume control before requesting systemd power-off. The logs contain compact success markers and host input checksum checks.

Set `COLD_BOOT=1` and provide `qemu-img` to reuse one private QCOW2 child of the read-only disk for a second cold boot. The first process must fully power off before the next starts. The runner requires different Linux boot IDs, preexisting enrollment and panel markers before the second login, no password enrollment UI, and successful touch-only login with the same in-memory credential. Guest logs for the two boots go in `first/` and `cold/`. The virtual display uses the desktop scale selected by the unmodified product policy.

Use `SCREEN_LOCK=baseline` or `SCREEN_LOCK=candidate` for the separate single-boot test of locking and unlocking an existing desktop. [Required inputs and session-lock checks](../../docs/SCREEN-LOCK.md#run-the-virtual-test)

Use `SCREEN_LOCK=installed` with a dev12.6 root and `UV_ARM64` pointing to an ARM64 Linux uv binary to test the packaged desktop. The guest checks the complete 1,115-package inventory, the rotation client, and the existing Xfce autostarts before the lock test. It gets the test observer from the copied EFI partition and all desktop packages from the candidate root. With `COLD_BOOT=1`, the test exercises the screen lock, PAM and draft recovery again after power-off and a second login.

With `POWER_DESKTOP=1`, supply the dev12.7 root. The guest checks the entire 1,124-package inventory and requires the packaged Xfce power manager to own its bus name in the logged-in user's session and UPower to be active on the system bus. The QEMU virtual board has no Y700 battery.

Set `POWER_DESKTOP=1 BLUEMAN_UPDATE=1` for the dev12.7 Blueman update or dev12.8. The runner copies the expected Blueman receipt to the test ESP. For dev12.8 it also validates the platform archive receipt. The guest checks its complete inventory and package files, then confirms the ambient-light client starts as the logged-in user with automatic brightness disabled.

## Boot the media editions

Use the 192 × 112 silent H.264 colour-pair clip from the [desktop player fixtures](../../docs/VIDEO-PLAYER.md). The 24-second stream-copy loop keeps the pattern visible during first launch. The guest reads the synthetic clip and observer from the copied ESP. Its media packages, desktop association and plugins come from the sealed root.

```sh
POWER_DESKTOP=1 BLUEMAN_UPDATE=1 MEDIA_DESKTOP=1 \
    MEDIA_CLIP="$clips/h264.mp4" UV_ARM64="$arm64_uv" IW_ARM64="$arm64_iw" \
    bash tests/combined-efi/run.sh "$root" "$root_sha" "$esp" "$esp_sha" \
        "$virt_uboot" "$virt_dtb" ./media-efi-logs
```

The observer checks the running guest's 1,240 installed package tuples and its media lock. After touch enrollment and LightDM login, it inherits the actual Xfce session's environment and invokes `gio open` as that user. It resolves both MP4 and WebM handlers, checks the Parole PID and clip argument, and samples three changing colour pairs on the visible desktop. The playback receipt reports the private registry, the V4L2 plugin mappings and any loaded software decoder plugins. QEMU exposes a framebuffer and no Qualcomm video accelerator.

For dev12.10, add `MEDIA_EDITION=dev12.10` to the command and use the root and EFI files unpacked from the dev12.10 TAR. The observer verifies the update receipt, all installed Parole package files and the executable of the player that opened the clip. The default media edition is dev12.9.

The sealed root `e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb` passed this test with boot FAT `495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6`. The running inventory digest was `89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d`. The clip `a45468cdbd00837f2edfe136338471071083686de9dcb2d3c2654312202c3ee6` displayed red/green, green/blue and blue/red on the 1024 × 768 desktop at 1× scale. Parole loaded `libgstlibav.so`. Its private registry indexed the customized V4L2 plugin, and both V4L2 plugin copies stayed unloaded on this VM. The guest powered off and the source hashes matched again. The reduced receipt is `out/dev12.9-board-verified/efi-boot.log`, SHA-256 `3ee359aa6673fb50d65eeb2459a0051f98f2a3920a7825d12913d653ce49ea26`. [Physical Iris playback evidence](../../docs/VIDEO-PLAYER-INTEGRATION.md)

The dev12.10 run used the root and boot FAT extracted by the distributed unpacker from TAR `ded90f1450d3d43642a3c8a7fe3077af7d6e59d9f9bb2b3485207edcfe0077eb`. The guest verified all 1,240 package tuples, accepted touchscreen enrollment and logged in through PAM. The user's default Parole process matched the installed y7002 executable and displayed all three colour pairs using `libgstlibav.so`. The guest powered off and the host verified the input hashes again. The reduced receipt is `out/dev12.10-board-verified/efi-boot.log`, SHA-256 `5f0f38a304f15cf05fee31ed4ea8280ee0f8af380f1204ab3678a9649fd219ef`.

The packager rejected a dev12.9 root labeled dev12.10, a stale package manifest, and a forged new package version and manifest with an old private plugin. With the correct private plugin and the old Parole executable, it identified `/usr/bin/parole` as the first mismatched file. Rebuilding the earlier dev12.9 TAR reproduced its recorded SHA-256. The results are in `out/dev12.10-board-verified/board-package-checks.log`.
