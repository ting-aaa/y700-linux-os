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

## Single-boot RTC1 probe

The RTC1 probe boots from the installed dev12.10 recovery entry and reuses its exact kernel and initrd. The two-file supplement adds a board DTB with the PMK8350 RTC enabled and numbered `rtc1`, and a BLS template. To rebuild the local archive on a Linux PC, use the verified recovery entry, the numbered board DTB and a fresh output directory.

```sh
bash scripts/build-rtc1-entry.sh "$RECOVERY_ENTRY" "$RTC1_DTB" "$work/entry"
(cd "$work" && tar --sort=name --mtime=@1795150416 --owner=0 --group=0 --numeric-owner --mode=0700 -cf - entry | gzip -n >rtc1-entry.tar.gz)
```

On the running permanent recovery system, use the privately mounted outer ESP for `add` and `remove`. The installer keeps the uncounted template in `EFI/y700-rtc1-12-10/source.conf`, outside the boot menu. The controller makes only a counted probe entry and a recovery fallback visible. Confirmation checks the EFI selection, running DT alias, boot identity, root, active services and deadline. The four-minute timer stays active after confirmation. On the fallback, restore the saved default and remove the supplement.

```sh
bash scripts/manage-file-trial-entry.sh --dev12.10-rtc1 add "$work/entry" "$OUTER_ESP"
bash scripts/arm-installed-trial.sh --rtc1 arm "$RUN_ID"
# After booting the counted probe
bash scripts/arm-installed-trial.sh --rtc1 confirm "$RUN_ID"
# After returning to the recovery system
bash scripts/arm-installed-trial.sh --rtc1 restore "$RUN_ID"
bash scripts/manage-file-trial-entry.sh --dev12.10-rtc1 remove "$work/entry" "$OUTER_ESP"
```

The 23,671-byte archive has SHA-256 `74bd49497c80637efb43ae8b895d611fb76d2280ab73ef202c80119d8e74553c`. The FAT transaction fixture is `tests/installed-trial/rtc1-arm.sh RECOVERY_MENU_QA_DIR RTC1_ENTRY NEW_WORK`. Its armed menu can be passed to `recovery-firmware.sh --rtc1` with the same arguments as the recovery firmware test. On ARM64 QEMU the first EFI selection consumed the counter and provided a virtual PL031 RTC alias. The second selected the recovery fallback with the original virtual tree. Receipts are in `out/dev12.10-rtc1-trial/`. PMIC alarm delivery is measured separately on the tablet.

## Single-boot CCI0 clock probe

The installed dev12.10 recovery kernel and initrd also support a counted probe for the rear camera control bus clock. The supplied board tree adds two properties to `/soc@0/cci@ac15000`. They select clock 8 on the camera clock controller and request 37,500,000 Hz. The builder removes the two properties from a scratch copy and compares the entire decoded tree with the sealed recovery DTB. At arm and confirm time the controller checks the paths and bytes of every assigned clock, clock parent and clock rate in the running tree. There are 20 properties on the recovery tree and 22 on the probe. The applied hardware rate requires a separate measurement.

```sh
bash scripts/build-dt-probe-entry.sh --cci0 "$RECOVERY_ENTRY" out/camera-cci-clock/cci0-37500000.dtb "$work/entry"
(cd "$work" && tar --sort=name --mtime=@1795150416 --owner=0 --group=0 --numeric-owner --mode=0700 -cf - entry | gzip -n >cci0-entry.tar.gz)
bash scripts/manage-file-trial-entry.sh --dev12.10-cci0 add "$work/entry" "$OUTER_ESP"
bash scripts/arm-installed-trial.sh --cci0 arm "$RUN_ID"
# In the counted boot, with the four-minute return timer still active
bash scripts/arm-installed-trial.sh --cci0 confirm "$RUN_ID"
# After returning to the recovery system
bash scripts/arm-installed-trial.sh --cci0 restore "$RUN_ID"
bash scripts/manage-file-trial-entry.sh --dev12.10-cci0 remove "$work/entry" "$OUTER_ESP"
```

Two builds produced the same 23,663-byte archive, SHA-256 `868979edce4e53e1aefefb12b0832fed1fc4eeecee6f4638a375b8b490159968`. Repeat the FAT transaction with `tests/installed-trial/rtc1-arm.sh --cci0 RECOVERY_MENU_QA_DIR PROBE_ENTRY NEW_WORK`, then run `recovery-firmware.sh --cci0` with the five firmware fixture arguments above. The transaction rejected a tree with an additional clock assignment on CCI1. The ARM64 guest used the two CCI0 properties on an unbound node of its virtual DT. The first EFI boot consumed the attempt and the second selected the recovery tree. Local logs are in `out/dev12.10-cci0-trial/`.

## Single-boot HI1339 LDO5 probe

The LDO5 entry stages a kernel and a device tree under `EFI/y700-ldo5-12-10`. It uses the installed recovery initrd. Both trees retain the baseline CCI0 clock configuration and disabled PMK8350 RTC. In the probe tree, the HI1339 `aux-supply` references the WL2864C LDO5 regulator with its original 2,800,000 µV constraints. The controller checks the running kernel notes, the regulator phandle, all supply references and all assigned-clock properties. The compiler renumbers some existing phandles when it creates the first reference to this regulator. The baseline and probe checks each use their respective digests.

```sh
bash scripts/build-camera-ldo5.sh "$PREPARED_KERNEL" "$work/image"
bash scripts/build-dt-probe-entry.sh --ldo5 "$RECOVERY_ENTRY" "$work/image" "$work/entry"
(cd "$work" && tar --sort=name --mtime=@1795150416 --owner=0 --group=0 --numeric-owner --mode=0700 -cf - entry | gzip -n >ldo5-entry.tar.gz)
bash scripts/manage-file-trial-entry.sh --dev12.10-ldo5 add "$work/entry" "$OUTER_ESP"
bash scripts/arm-installed-trial.sh --ldo5 arm "$RUN_ID"
# On the counted boot, while the four-minute return timer is active
bash scripts/arm-installed-trial.sh --ldo5 confirm "$RUN_ID"
# After returning to recovery
bash scripts/arm-installed-trial.sh --ldo5 restore "$RUN_ID"
bash scripts/manage-file-trial-entry.sh --dev12.10-ldo5 remove "$work/entry" "$OUTER_ESP"
```

The 16,056,721-byte archive has SHA-256 `97573e56f3b1a9b39a2457abb456454e8ebe812798bdfbc9e7b87c4bb9c92663`. Repeat the FAT transaction and ARM64 firmware fixture above with `--ldo5`. The EFI guest executed the exact probe kernel on the counted boot and the exact previous kernel on the second boot. The observer read their distinct notes and a synthetic auxiliary supply reference on the virtual tree. Traces are in `out/dev12.10-ldo5-trial/`. Physical regulator activity and hardware identification require separate evidence.
