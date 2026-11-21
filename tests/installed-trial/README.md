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
