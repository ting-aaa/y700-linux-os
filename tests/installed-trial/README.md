# Single-attempt installation boot

The baseline boots from the original UFS root and the outer FAT ESP. The dev12.10 candidate boots from its two private image files. The stable candidate entry is `y700-file-12-10.conf`. Its SHA-256 is `1c5c6829f6349cfae5fcaac0e9844ac88dcc01ba18adf787a317aff2ad8d41bc`.

Run the following on the mounted, personalized 32 GiB image before unmounting it. Keep a copy of the same script accessible over the original and candidate USB SSH connections.

```sh
bash arm-installed-trial.sh prepare-candidate /path/to/mounted/candidate
```

After installing and checking the candidate EFI entry and its payloads, run the following as root on the original system. Use a new run ID.

```sh
run=install-01
entry_sha=1c5c6829f6349cfae5fcaac0e9844ac88dcc01ba18adf787a317aff2ad8d41bc
bash arm-installed-trial.sh arm "$run" "$entry_sha"
```

On the next boot, systemd-boot consumes the candidate's single attempt on the **outer** FAT before it starts the kernel. If the operating system reboots again, the original entry wins. The new root starts a four-minute timer when it sees the per-run kernel option. It requests an orderly reboot if the operator has not confirmed over SSH. A CPU or firmware hang still needs an external reset.

After reconnecting over USB and verifying the new desktop's health, use the same run ID and digest in the candidate. `confirm` verifies the installed release, both loop backing inodes, the active deadline, SSH and LightDM, records the new boot ID on the outer UFS and stops its timer. `promote` verifies the consumed counter and makes the ordinary dev12.10 entry the default. The original Debian entry remains available in the boot menu.

```sh
bash arm-installed-trial.sh confirm "$run" "$entry_sha"
bash arm-installed-trial.sh promote "$run" "$entry_sha"
```

Run `promote` in the same verified candidate boot as `confirm`. It checks that the deadline is inactive and that systemd and logind have no pending shutdown. If the candidate has already rebooted, restore the original default and use a new run ID for another trial. To restore the pre-trial default and remove the two test entries, run `bash arm-installed-trial.sh restore "$run" "$entry_sha"`. In the candidate the script acquires the outer ESP in a private mount namespace. State under `/var/lib/y700-trial/control-RUN_ID` belongs to the outer UFS. Every transition compares the original loader configuration, entry definitions and referenced firmware payloads to their saved values.

## PC verification

`bash tests/installed-trial/arm.sh` exercises the FAT transaction, re-entry, altered files, confirmation gate and rollback. It prepares and reads back both systemd units on a disposable 32 GiB ext4 image. For the bootloader proof, run the existing ARM64 QEMU/U-Boot harness with a fresh output directory.

```sh
uv run --offline --no-project --python /usr/bin/python3 python tests/tablet-boot-count.py \
  --attempts 1 "$BOARD_BUILD" "$QEMU_TOOLS" "$NEW_WORK"
```

The first boot selects the trial. The kernel panics on its deliberately absent root, waits three seconds, and resets. The second firmware boot selects the original entry. Both reads of the same FAT contain `trial+0-1.conf`. This harness checks firmware selection, and does not exercise a physical reset or the candidate desktop.

## Recovery entry on an installed dev12.10 system

Install the four checked recovery EFI files on the outer ESP using `manage-file-trial-entry.sh --dev12.10-recovery add`. With the standard dev12.10 file entry running as the permanent default, arm one boot using a fresh run ID.

```sh
run=recovery-01
entry_sha=21b05d85897a5047834766a5ae1629203d6fad6fd43d0aa614c110b1f3bfa834
sudo bash arm-installed-trial.sh --recovery arm "$run" "$entry_sha"
```

The script checks the installed file-root pair and the effective deadline units on the running system. It opens the outer ESP in a private mount namespace and verifies both entry manifests. The fallback uses the working `y700-file-12-10.conf` payload. The original `debian.conf` remains available. After this counted boot, run the desktop acceptance checks while the four-minute deadline is active. Confirm and promote in the same boot after those checks pass.

```sh
sudo bash arm-installed-trial.sh --recovery confirm "$run" "$entry_sha"
sudo bash arm-installed-trial.sh --recovery promote "$run" "$entry_sha"
```

For rollback, run `sudo bash arm-installed-trial.sh --recovery restore "$run" "$entry_sha"`. This restores the exact saved loader configuration. Each recovery run has a separate `recovery-control-RUN_ID` directory on the outer ext4.

Run `bash tests/installed-trial/recovery-arm.sh RELEASE_ENTRY RECOVERY_ENTRY GENERIC_ESP NEW_WORK` as root on a Linux PC. Use a new work directory under `/var/tmp/y700-recovery-menu.*`. The test installs the checked files on a new FAT, exercises tampered payloads and wrong boot identities, and preserves the armed BLS entries for the optional firmware test. Run `bash tests/installed-trial/recovery-firmware.sh NEW_WORK VIRT_UBOOT VIRT_DTB ARM64_BUSYBOX EFIVARFS_KO_ZSTD` to exercise two boot-manager selections. The firmware fixture uses a virtual-machine DTB, the matching kernel module and a small observer initramfs to read the actual EFI selected-entry variable and to reset after the first selection.
