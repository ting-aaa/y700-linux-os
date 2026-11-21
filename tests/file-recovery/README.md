# dev12.10 nested filesystem power-cut regression

On a Linux PC, supply the generic unpacked dev12.10 images, the released file entry and the recovery entry. The scratch directory must be a new path under `/var/tmp` matching the example. The test needs root for private loop mounts, a 3 GiB ARM64 QEMU machine, and space for three sparse copies of a disk containing the 6 GiB product root and 1 GiB ESP. Set `QEMU_SYSTEM_AARCH64` and `QEMU_DATA` when using a standalone QEMU build.

```sh
work=/var/tmp/y700-file-recovery.example
sudo bash tests/file-recovery/run.sh cut "$IMAGES" "$RELEASE_ENTRY" "$work"
sudo bash tests/file-recovery/run.sh verify "$IMAGES" "$RECOVERY_ENTRY" "$work"
```

For the installed layout, use `cut32` in place of `cut` with a fresh scratch directory, followed by the same `verify` command. The preparation runs e2fsck and resize2fs on the copied root and verifies the resulting 32 GiB filesystem before the first guest boot. The outer virtual disk then provides a 38 GiB partition. The guest reads its own root capacity and the outer logical sector size.

The test constructs a private 4 KiB-sector GPT disk. The original entry boots the released root into systemd with the two nested files mounted read-write. A read-only test drive supplies the observer. The observer writes a marker to each nested filesystem and calls `fsync` on the files and parent directories. On that exact serial checkpoint the host kills only its QEMU process with SIGKILL. This discards guest RAM while leaving the host and source images running normally.

The old entry receives the stopped disk through a disposable snapshot. The recovery entry receives a byte-identical private copy. The tests record the kernel's journal replay, both marker contents, QEMU's orderly shutdown, both ext4 superblock states, read-only e2fsck results, FAT32 state bytes and the full read-only fsck.fat report. The last boot checks that changing the inner release receipt on a clean clone still prevents entry. `dirty.sha256` identifies the common starting bytes. `power-cut.log`, `original-refused.log`, `journal-recovery.log`, `incompatible-refused.log` and `result.log` contain the individual outcomes.

QEMU uses the released ARM64 kernel and the supplied entry's initrd and arguments. Direct kernel boot skips the firmware menu. The virtual disk models an interrupted guest and surviving backing storage. A physical UFS controller losing its own power has additional write-cache behavior.

Both root sizes passed with the recovery entry manifest `36132af676bfd7b14f7ef954c1d9329e1dc8eb77c0c99d5301eab412b5c18b0b`. In both snapshots the original entry refused the dirty outer ext4. The recovery kernel replayed the outer and inner journals, mounted the checked FAT read-write, read both markers in systemd and shut down cleanly. Both subsequent e2fsck runs and fsck.fat returned zero. The damaged-cut FAT had a main boot byte of `0x01`, a clean backup byte, and an FSInfo free-cluster count one above the true count. The separate wrong-release case powered down before entering the product systemd. The receipts are in `out/file-recovery-dev12.10/root-6g/` and `out/file-recovery-dev12.10/root-32g/`.
