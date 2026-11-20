# Early regulatory database on ARM64

Run the three radio-free QEMU guests on a Linux PC. Use a trusted Y700 kernel
and the gzip/newc initramfs from its EFI partition, an integrated Debian ARM64
base, and the ARM64 `iw` executable from Debian. The test uses the base's
`wireless-regdb`, libc and libnl files without changing that root. The log
directory must be new. QEMU, cpio and gzip run on the host.

```sh
mcopy -i linux-boot.fat ::/EFI/debian/kernel.efi Image
mcopy -i linux-boot.fat ::/EFI/debian/initrd board-initrd
dpkg-deb -x iw_6.9-1+b1_arm64.deb iw-tools
bash tests/wifi-regdb/early-boot.sh Image board-initrd "$ARM64_ROOT" \
    iw-tools/usr/sbin/iw regdb-boot-logs
```

Each guest has the same board BusyBox and WCN6855 firmware, a test PID 1 and
the kernel parameter `cfg80211.ieee80211_regdom=CN`. The guest queries
`iw dev` and `iw reg get` in the initramfs. With no disk or wireless device
attached, the kernel can only obtain the rules from the early archive.

| Initial archive contents | Expected kernel evidence | Global domain |
| --- | --- | --- |
| No generic database or signature | Failed firmware request | `00` |
| Production staging of the locked upstream-signed pair | Applies the test hint | `CN` |
| Same database bytes with the Debian signing key | Signature rejected | `00` |

The country hint is confined to the test command line. Hardware association,
channel availability and data transfer require a separate physical test.
