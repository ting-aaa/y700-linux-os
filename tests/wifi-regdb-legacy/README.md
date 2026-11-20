# Regulatory database recovery with an old initramfs

Run this check on a Linux PC with QEMU, Bash, cpio, gzip and dpkg-deb. Supply the Y700 `Image`, original gzip/newc initramfs without `regulatory.db` or its signature, a read-only integrated ARM64 ext4 root, and the authenticated Debian ARM64 `iw` archive. The root must have the original `wireless-regdb` alternatives in auto mode and have no `iw` or Y700 fallback unit installed. Set `ROOT_FORMAT=qcow2` for a QCOW2 root. `QEMU_SYSTEM_AARCH64` and `QEMU_DATA` can identify a private QEMU installation.

```sh
ROOT_FORMAT=qcow2 bash tests/wifi-regdb-legacy/run.sh \
    Image legacy-initrd debian-root.qcow2 iw_6.9-1+b1_arm64.deb
```

The original gzip/newc member is copied unchanged into a temporary boot archive, followed by a separate test member. The disposable guest places all root changes in a RAM overlay, installs `iw`, selects the upstream-signed alternatives, and enables the exact fallback unit. PID 1 then starts NetworkManager through its normal systemd dependency graph. The check requires the kernel's early missing-file error, an active/exited fallback unit with exit status zero, and an active NetworkManager whose monotonic activation timestamp follows the fallback's.

Before the guest powers off, it removes the test unit and `iw`, restores the original alternatives query in full, and verifies that NetworkManager remains active. The test runs without radios, a regulatory country hint or external network access. It verifies cold boot ordering and the reload command in the legacy recovery path. It does not measure per-channel rules or radio behavior.
