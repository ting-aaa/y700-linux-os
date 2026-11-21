# Rebuild and test Y700 touch-enabled Thunar

The shared exercise checks directory navigation, hold menus, typing through Onboard and the resulting paths inside a private home. It uses Icons, the shipped double-click mouse setting, and the release's Onboard configuration. The toolbar's Up button is tapped on its left side so that the stock floating keyboard button can stay visible. [Touchscreen user guide](../../docs/THUNAR-TOUCH.md)

## Build the Debian package

Use a Debian 13 arm64 build environment with `build-essential`, `binutils`, `dpkg-dev`, `patch`, `pkg-config`, `intltool`, `libtool`, `gettext`, `libgtk-3-dev`, `libexo-2-dev`, `libxfce4ui-2-dev`, `libxfconf-0-dev`, `libgudev-1.0-dev`, `libnotify-dev`, `libsm-dev`, `libice-dev` and `libthunarx-3-dev`. The reference build used GCC 14.2.0-19, binutils 2.44-3, dpkg 1.22.22, GTK 3.24.49-3 and Exo 4.20.0-1. The three input hashes are pinned by the recipe. Copies of the source archives and the Debian source control file are in the local artifact directory. Debian publishes them under the original filenames. [Debian source](https://sources.debian.org/src/thunar/4.20.2-1%2Bdeb13u1/), [Debian package pool](https://deb.debian.org/debian/pool/main/t/thunar/)

```sh
out=out/thunar-touch
bash packaging/thunar-touch/build.sh \
    "$out/thunar_4.20.2-1+deb13u1_arm64.deb" \
    "$out/sources/thunar_4.20.2.orig.tar.bz2" \
    "$out/sources/thunar_4.20.2-1+deb13u1.debian.tar.xz" "$out"
```

The recipe applies the Debian patch series and the local direct-touch change. It rebuilds the arm64 executable, transplants it into the verified distribution package, updates the file checksums and checks every regular payload file. Its plugins, icons and shared files come from the original package. The patch listens to GDK touch events in the Exo icon window. It uses the primary contact's original timestamps and converts root coordinates to viewport coordinates for Exo's hit test after scrolling. The hold opens Thunar's existing native menu for the item or background. The separate Detailed List widget is outside this patch. [Debian icon view implementation](https://sources.debian.org/src/thunar/4.20.2-1%2Bdeb13u1/thunar/thunar-abstract-icon-view.c/), [GTK scrolled-window event handling](https://docs.gtk.org/gtk3/method.ScrolledWindow.set_capture_button_press.html)

Two separate clean builds produced the same 376,264-byte package. Both archives had 41 payload entries, with one different executable. Its 21 `DT_NEEDED` entries retain their original order. Local receipt `out/thunar-touch/pc-build.log`.

| Artifact | SHA-256 |
| --- | --- |
| Debian rollback package | `f390240509b742d58c35a50bad12d31e9168e557ddb6dcf708e26724c4a33ea7` |
| Touch package | `f0ecf50c5fbbd36acdeaab07efc3787bdef7be853fc06a4e94747b4aa67b9dee` |
| Touch executable | `02caf12619717678c5b615a1c06c89ff21390966c2b348c07cf4a05216342b8d` |

## Replay direct contacts

The PC fixture boots the existing dev12.13 raw root read-only on the project's ARM64 kernel. A temporary RAM overlay receives the package. It starts Xorg, Xfwm, Onboard and Thunar under the ordinary desktop account with a disposable home, display and D-Bus. AT-SPI locates visible controls. The injector supplies Linux multitouch Type-B reports, and the actor verifies the newly created and renamed directories. The pointer regression closes its private Onboard copy before it sends XTEST mouse clicks.

Supply the released raw root, its matching kernel, a static arm64 BusyBox, the arm64 Debian Xorg dummy video driver and an arm64 uv binary. The shared topology fixture pins the checksum of the dummy driver at `out/thunar-touch/qa/xserver-xorg-video-dummy_0.4.0-1+b2_arm64.deb`. The host needs the AArch64 cross C compiler, `qemu-system-aarch64`, `cpio` and `gzip`. A local QEMU installation can set `QEMU_SYSTEM_AARCH64` and `QEMU_FIRMWARE_DIR`.

```sh
bash tests/thunar-touch/run.sh "$root_ext4" "$kernel" "$busybox" "$dummy_deb" "$uv_arm64"
Y700_THUNAR_DEB=out/thunar-touch/thunar_4.20.2-1+deb13u1+y7001_arm64.deb \
    bash tests/thunar-touch/run.sh "$root_ext4" "$kernel" "$busybox" "$dummy_deb" "$uv_arm64"
```

For the separate tablet test, the shared actor accepts `Y700_THUNAR_TOUCH` pointing to a private Xorg input adapter. Its arguments are `tap|hold X Y` in physical screen pixels. The test uses only its own temporary directories. Physical glass and a Bluetooth mouse require separate observation. [Tablet test](../thunar-board/README.md)

The stock check requires the folder to remain selected after one tap and the native rename menu to stay closed after a 1.1 s hold. The touch package must open the folder twice, navigate back, forward and up, and present the correct two context menus. It types `hello` on Onboard, verifies the created directory, renames it to `oh` and verifies both paths. A moved contact ending back at the start and two simultaneous contacts must leave the original directory open.

The pointer check requires single-click selection and double-click navigation at both 100% and 200%. At 200% it also holds Shift or Control during a Type-B tap, then uses a direct upward swipe in a directory of 96 folders. An ordinary mouse click identifies the newly visible folder independently via the status bar. A touch at the same location must open that exact folder. See `out/thunar-touch/pc-stock.log` and `out/thunar-touch/pc-release.log`.
