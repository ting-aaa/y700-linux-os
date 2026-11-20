# File-backed dev12.5 in a disposable EFI guest

Run on a Linux PC as root. The fixture requires `e2fsprogs`, `dosfstools`, `util-linux`, `mtools`, a static AArch64 cross compiler, AArch64 QEMU, `qemu-img`, `qemu-nbd`, the NBDKit split plugin, nbdfuse, FUSE and uv. Use the sealed generic dev12.5 root and FAT, the exported file-trial supplement, and the project's virtual U-Boot and board DTB.

```sh
bash tests/file-trial-positive/prepare.sh "$root" "$esp" "$scratch/baseline"
bash tests/file-trial-positive/run.sh "$scratch/baseline" "$entry" \
    "$esp" "$virt_uboot" "$virt_dtb" "$scratch/logs"
```

The baseline fixture is a regular 9 GiB ext4 file with the expected baseline UUID and board image marker. It contains byte-identical copies of the delivered root and FAT in the guarded trial directory. The runner supplies a 4096-byte-sector GPT, a private outer EFI partition, and this sealed backing file. The trial's kernel and initramfs are checked byte-for-byte. The private outer ESP receives the virtual device tree, trial menu selection, serial logging and guest test observer. QEMU writes only to a disposable QCOW2 layer.

The first boot checks the EFI selection and actual initial program, then proves `/` and `/boot` are writable loop mounts backed by the expected files and inodes on the original outer ext4. It runs normal touchscreen enrollment and LightDM login from the combined EFI test. A second QEMU process reuses the same overlay and verifies persisted enrollment and login through the same virtual touchscreen. The firmware, package inventory and active ordinary Xfce session are required gates for both boots. Reports also record Onboard and panel volume readiness after login, with a separate result for each timeout or unmet condition.

The host checks the rendered Arctica username and password screens, enters both through the virtual touchscreen, and sends a separate notification after the final tap is acknowledged. The guest then has 120 seconds to observe the normal LightDM session in logind. A separate 300-second Xfce deadline starts when that session appears. The acceptance check requires the active local Xfce desktop to belong to that same ordinary seat0 session. The notification and logs contain no passwords.

The observer samples optional keyboard and panel state in the background for up to six seconds after Xfce is confirmed. It records an unfinished check as unconfirmed and continues to normal power-off.

After shutdown the runner exports a read-only view of the modified disk. It requires clean outer and nested ext4 superblocks, no recovery flag and `e2fsck -fn` success. It mounts the outer file system with `ro,noload` to inspect the nested root and FAT. The nested FAT must pass `fsck.fat -vn`. The original source, trial supplement and backing file hashes are rechecked.

Tool overrides are `AARCH64_CC`, `UV_BIN`, `QEMU_SYSTEM_AARCH64`, `QEMU_IMG`, `QEMU_NBD`, `QEMU_DATA`, `QEMU_LIB`, `NBDKIT`, `NBDKIT_SPLIT` and `NBDFUSE`. Keep the work directory on a regular Linux filesystem with room for the nested image data. This test uses a virtual 4Kn disk, the test device tree and automatic selection of the trial menu entry.
