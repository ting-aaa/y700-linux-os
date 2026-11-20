# RAM trial storage policy

On a Linux build PC, run the following with root privileges, `uv`, QEMU AArch64, an AArch64 C compiler, GNU cpio, binutils, util-linux, zstd and udevadm.

```sh
bash tests/ram-media/run.sh /path/to/dev12.5/root.ext4 /path/to/ram-bundle /new/log/directory
```

The runner mounts the pinned source ext4 read-only in a private mount namespace. It boots the bundle's board kernel in a 512 MiB virtual machine with the original BusyBox, the target Debian udev daemon, and the exact cold-device loop and udev rules extracted from the supplied initramfs. Set `QEMU_SYSTEM_AARCH64`, `QEMU_DATA` and `AARCH64_CC` if these tools live outside the normal host search path.

The virtual machine receives two fresh writable disk files with independent data and MBR partitions. A virtio disk is present at power-on. The runner attaches a USB disk through QMP after the guest requests it. After udev settles, the guest checks the read-only flag and UDisks policy on each disk and partition. If Linux grants a writable file descriptor, the guest attempts one aligned 4096-byte write at offset 4096, then calls `fsync` and `close`. The test requires denial of the write and compares both complete disk hashes before and after the guest. See `check.log`, `serial.log` and `policy.sha256` in the output directory.

This exercises the volatile storage policy on the target ARM64 Linux kernel. A privileged process can clear the kernel read-only flag. The fixture covers the state after device discovery and udev settlement.
