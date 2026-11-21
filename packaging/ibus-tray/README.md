# IBus GTK tray menu

IBus 1.5.32 installs its GTK status-icon menu callbacks when Xfce reports the icon size. Repeated size notifications leave the old callbacks connected. The patch disconnects both old callbacks before connecting their replacements, so one tap opens one menu at the updated position. The original keyboard, candidate widgets and language engines remain in their Debian packages. [IBus tray handlers](https://github.com/ibus/ibus/blob/1.5.32/ui/gtk3/panel.vala#L441-L507) · [Upstream issue](https://github.com/ibus/ibus/issues/2967)

Use a Debian trixie ARM64 build environment with the source package's build dependencies for profiles `nocheck,nodoc,noinsttest`. Place the original Debian source files and binary in the input directory and create an empty output directory. [Debian source](https://deb.debian.org/debian/pool/main/i/ibus/) · [Binary package lock](../../config/chinese-ime.lock.json)

```sh
apt-get source --download-only ibus=1.5.32-2
apt-get download ibus:arm64=1.5.32-2
apt-get -Pnocheck,nodoc,noinsttest --no-install-recommends build-dep ./ibus_1.5.32-2.dsc
mkdir -p packages
bash /path/to/scripts/build-ibus-tray.sh . ./ibus_1.5.32-2_arm64.deb packages
```

The builder checks all four inputs, applies the patch to Debian's Vala source, rebuilds the GTK panel with Debian's feature switches and compares its direct shared-library dependencies to the original. It packages the panel at the original `/usr/libexec/ibus-ui-gtk3` path in `ibus_1.5.32-2+0y7001_arm64.deb`. Keep the original `ibus_1.5.32-2_arm64.deb` for rollback. The hash pins for the three source files were verified against Debian's signed trixie InRelease (`bfacad4ca61899ce20d4a0d439f29339f66541561b67506364efb88e27dee870`) and its main Sources.xz (`b449439c113900c8607c1005f7a1ec0704d0f3b7376ba312b2150c79e4e4e06c`) on 2026-11-21.

Two clean ARM64 builds produced the same archive, SHA-256 `6bff9a687f7459293a6a318adc216c02d0bf4c7f2332bffd9f6204d04b29784d`. Of 88 payload members, only the panel changed, to SHA-256 `fcd6398a9addf82ddb6a7841b78343c57a9ec6a118c59cd85c8b1d7171351cae`. The panel retained all 20 direct library dependencies. A private writable overlay of the sealed dev12.12 root passed installation, repeated installation and rollback. At each step all 1,240 packages resolved, `dpkg --audit` was empty, the installed panel resolved all symbols under `ldd -r`, and unrelated package tuples matched the original. Rollback restored the full original inventory.
