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
