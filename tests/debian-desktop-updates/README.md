# Debian graphical updates on an ARM64 tablet seat

The two runs use the same dev12.13 read-only root, the released ARM64 kernel and a new RAM overlay per boot. The VM has 1,536 MiB, no network device and a local signed APT repository containing one candidate, `y700-qa-updater` 2.0. Version 1.0 is installed first. Test signing keys stay in a temporary host directory. The guest receives the public key.

From a Linux build host, provide the same ARM64 static BusyBox, Xorg dummy-driver .deb and ARM64 uv used by the project's touch fixtures. The runner checks the root, kernel, dummy driver and application packages by SHA-256. It needs GNU coreutils, bash, dpkg, GnuPG, cpio, gzip, the AArch64 compiler and qemu-system-aarch64. Set `QEMU_SYSTEM_AARCH64` and `QEMU_FIRMWARE_DIR` for a private QEMU build.

```sh
bash tests/debian-desktop-updates/run.sh "$root" "$kernel" "$busybox" "$dummy" "$uv" "$debs"
bash tests/debian-desktop-updates/run.sh "$root" "$kernel" "$busybox" "$dummy" "$uv" "$debs" "$product_debs"
```

`debs` contains gnome-package-updater and gnome-packagekit-common 43.0-4, plus packagekit and libpackagekit-glib2-18 1.3.1-1+deb13u1. `product_debs` supplies the matching gir1.2-packagekitglib-1.0 and y700-software-updates 0.1.0.

Both modes start systemd, logind, udev, PackageKit's apt backend, polkit, Xorg/libinput and xfwm4. PAM opens the local X11 session for UID 1000 on active seat0. GTK uses 200% scaling at 1600×2560. The signed repository uses a file URI. A loopback-only default route gives PackageKit its online state, and the guest uses the fixture creation time for APT signature validation.

- The first invocation opens Debian's regular desktop entry, reads the single selected update from GTK, and taps its Install button using a kernel Type-B touch device. A process-scoped Debian pkttyagent answers the ordinary system-update authentication via PAM with a disposable guest password. The transaction observer correlates the actual trusted install call and success signal by D-Bus object path. The test compares the package inventories, downgrades the one package with dpkg, and checks every original tuple and the marker again.
- The second invocation opens the Y700 desktop entry and waits without supplying touch or credentials. It requires `RefreshCache(true)` to finish successfully and the stock viewer to show the selected candidate. The complete installed inventory and version-1.0 marker must be unchanged.

The fixture exercises the virtual touch device and the native package transaction. Password entry is automated at the normal PAM terminal agent. Online Debian mirrors and the tablet's physical screen are outside this test.
