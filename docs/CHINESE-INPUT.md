# Chinese input with Onboard

Tap the input-language icon in the Xfce panel and choose **Chinese – Intelligent Pinyin**. Tap the text field to bring up Onboard, then tap the letters for the syllables you want. Tap the candidate or its number to commit it. The optional IBus update below fixes a missed first tap after switching languages. On a stock installation, if the candidate is still visible, tap it again or press Onboard Space to commit the highlighted candidate. To switch back, choose **English – English (US)** from the panel and continue typing with Onboard.

## Measured desktop path

The isolated ARM64 test starts an ordinary `y700` session through Debian Xsession and the shipped Xfce autostart. It uses the shipped 200% profile on a private 2560×1600 X11 display. Debian Xsession supplies the IBus GTK module and XIM setting. The test uses the stock IBus panel and the bundled Compact Onboard layout. [Test entry point](../tests/chinese-input/run-arm64.sh)

The test first taps from a non-editable GTK control into the empty text field. Five pointer taps on Onboard produce `nihao` and the real libpinyin popup. The application still reports empty committed text while the candidate is visible. The probe checks that the popup owns the candidate click, then requires the application itself to report committed `你好` and an empty preedit. Switching to English through the same tray menu and typing on Onboard leaves the field with exactly `你好 hello`. A Space fallback is recorded separately and cannot pass the popup-tap gate. [Application and popup assertions](../tests/chinese-input/probe.py)

Both placements passed on the final 1,112-package dev9 image with `y700-input-pinyin 0.1.0~dev3`. The upper popup was at `804,548` and clear of the keyboard. The lower popup was at `804,816` and overlapped the keyboard. XQueryPointer identified IBus as the input window in both cases. The first numbered tap left the preedit unchanged, and the second emitted `CandidateClicked(0, 1, 0)` on the private IBus bus and committed the phrase. [IBus candidate click implementation](https://github.com/ibus/ibus/blob/1.5.32/ui/gtk3/candidatearea.vala#L244-L270)

## Why the first candidate tap was lost

The dev12.12 release contains Debian IBus `1.5.32-2`, libpinyin engine `1.15.8-2`, and Onboard `1.4.1-10+y7002`. Under X11, each tray icon size notification can register another pair of IBus menu callbacks. On the 200% Xfce panel, one tray tap opened two language menus. Choosing Chinese closed the top menu. The other menu retained a GTK input grab. [IBus 1.5.32 tray implementation](https://github.com/ibus/ibus/blob/1.5.32/ui/gtk3/panel.vala#L440-L502) · [Upstream issue 2967](https://github.com/ibus/ibus/issues/2967)

A diagnostic run on the sealed ARM64 userspace traced both candidate presses to the same coordinates in the same IBus `GtkEventBox`. GTK dispatched the first press to the menu that still held the grab. On the second press, GTK dispatched to the candidate widget and IBus sent one `CandidateClicked(0,1,0)`. The GTK text field then reported committed `你好` and empty preedit. A separate AArch64 QEMU run reproduced the two-tap result with an unmodified panel, Xorg/libinput and 20 complete kernel Type-B contacts, including the later English switch and `你好 hello`.

## Optional IBus update

The ARM64 archive `y700-ibus-tray-offline.tar` contains the updated IBus package, the Debian rollback package and a checksum list. Its SHA-256 is `3126fddabe8c964d05d1fedf0d29886ed028a7036eb975b59f5051188c92edc9`. The update replaces the panel executable in the Debian package. After a size change, the panel disconnects the two previous menu handlers before registering the handlers for the new geometry. [Source patch](../packaging/ibus-tray/status-icon-single-menu.patch) · [ARM64 build recipe](../scripts/build-ibus-tray.sh)

Two fresh AArch64 guests exercised the updated package at 200% scale. Each tray tap produced one language menu. Each candidate tap produced one IBus event and committed `你好` to the GTK field. The English switch and six more Onboard keys yielded exactly `你好 hello`. The evdev reader counted 19 complete contacts in each session. [Type-B acceptance test](../tests/chinese-input/run-touch.sh)

| Candidate touched | Popup origin in physical pixels | Contact in physical pixels | Contacts to commit |
| --- | --- | --- | --- |
| Number, above Onboard | 804, 548 | 840, 644 | 1 |
| Word, overlapping Onboard | 804, 816 | 886, 914 | 1 |

Extract the archive to an empty directory and verify both files. Debian's package configuration removes the obsolete system autostart file `/etc/xdg/autostart/ibus.desktop`. If an administrator created that file on the target, preserve it before running the package operation. The sealed release has no such file. A running desktop picks up the updated panel at its next ordinary login.

```sh
sha256sum --strict -c SHA256SUMS
sudo dpkg --force-confold -i ./ibus_1.5.32-2+0y7001_arm64.deb
sudo apt-get check
dpkg-query -W -f='${Package}\t${Version}\n' ibus
sha256sum /usr/libexec/ibus-ui-gtk3
```

The installed panel SHA-256 is `fcd6398a9addf82ddb6a7841b78343c57a9ec6a118c59cd85c8b1d7171351cae`. To restore the Debian panel, run `sudo dpkg --force-confold -i ./ibus_1.5.32-2_arm64.deb`. Its panel SHA-256 is `e24502cba3f86af85fd183a1761eea75236414232c7211f0af75825aa519041d`.

The expected 1,240-package inventory for the sealed dev12.12 root changes from `ef9dea42…` to `d136f1cf7fe15eeebc2df70554f09650c9d26d002aeda659dc14907ed341b761`. For the installed dev12.11 desktop with the same platform updates, qcam y7007 and Blueman y7003, the expected change is `a434ec3c…` to `073a8831c0a7aa8cda470b59208cbfb258f546cd5e39cd36a792367959fb7430`. Both use the sorted package/version/architecture tuples from `dpkg-query`.

## Installed tablet software check

On 2026-11-20 the TB320FC_PRC passed the same Chinese and English entry test with its installed dev3 packages. A private 200% Xfce display ran on the tablet with a fresh home, isolated desktop bus and physical input devices hidden. Onboard entered `nihao`. The second numbered popup tap committed `你好`, and switching back to English and using Onboard left the GTK entry with `你好 hello`. The original boot, graphical seat, service invocations and account language matched before and after.

## Chromium

Chromium `156.0.8078.47` passed in an ARM64 VM on the same image and on the tablet in a separate private Xfce session. The browser opened a local test page, confirmed focus through `document.activeElement`, and reported the text committed into its actual DOM. After each IBus engine switch, a new focus transition from a button into the text field brought Onboard back automatically. Five letter taps produced the candidate. The numbered popup tap committed `你好` on its first try in one VM run. The tablet and an earlier VM run needed a second tap. The English tray switch plus Onboard then left the page with exactly `你好 hello`. The renderer used seccomp filtering, `NoNewPrivs`, and a separate PID namespace. [Browser fixture](../tests/chinese-input/chromium/browser-probe.py)

## Repeat on an isolated ARM64 image

Provide the dev9 IME image with its complete qcow2 backing chain, the expected leaf SHA-256, a host directory containing `qemu-nbd` and `nbdfuse`, ARM64 Debian `xvfb`, `xdotool` and `libxdo3` archives, and ARM64 `uv`. On x86 the fixture uses the Linux ARM64 binfmt interpreter. It mounts the image read-only in private namespaces. An optional sixth argument supplies a checksum-verified offline package directory for testing the IME layer in a disposable overlay. [Authenticated IME lock](../config/chinese-ime.lock.json)

```sh
sudo bash tests/chinese-input/run-arm64.sh \
  "$ROOT_QCOW2" "$ROOT_SHA256" "$NBD_BIN_DIR" "$X11_DEB_DIR" "$ARM64_UV"
```

Run with `sudo env CHINESE_INPUT_POSITION=lower bash …` to reproduce the geometry where the candidate popup overlaps the Onboard dock.

For Chromium, use a full ARM64 VM so the browser can create its renderer sandbox. Provide a bootable Y700 kernel and its expected SHA-256, an ARM64 static BusyBox, the X11 archive directory and ARM64 `uv`. The runner boots the supplied root read-only and serves the fixture only on guest loopback. [Chromium runner](../tests/chinese-input/chromium/run-vm.sh)

```sh
bash tests/chinese-input/chromium/run-vm.sh \
  "$ROOT_QCOW2" "$ROOT_SHA256" "$KERNEL_IMAGE" "$KERNEL_SHA256" \
  "$ARM64_BUSYBOX" "$X11_DEB_DIR" "$ARM64_UV"
```

The Xvfb and Chromium fixtures above use X11 pointer clicks. The Type-B fixture uses a board-shaped virtual touchscreen on the Y700 kernel. Finger input through the physical panel remains unmeasured.

For the release touchscreen regression, supply the verified dev12.12 raw root, dual-refresh kernel, ARM64 BusyBox, Debian Xorg dummy driver, ARM64 uv, and a directory containing the ARM64 `xdotool` and `libxdo3` test archives. The QEMU guest uses 1.5 GiB, its own buses and a read-only base disk. Xdotool is used to locate windows. Menu selection, text focus, all Onboard letters and the candidate selection use kernel Type-B contacts. The probe checks the visible IBus window at the intended coordinates without moving the pointer. [Touch fixture](../tests/chinese-input/run-touch.sh)

```sh
bash tests/chinese-input/run-touch.sh "$ROOT" "$KERNEL" "$BUSYBOX" "$DUMMY" "$UV" "$X11_DEBS" upper
bash tests/chinese-input/run-touch.sh "$ROOT" "$KERNEL" "$BUSYBOX" "$DUMMY" "$UV" "$X11_DEBS" upper "$FIXED_IBUS_DEB"
CHINESE_INPUT_CANDIDATE=word bash tests/chinese-input/run-touch.sh \
  "$ROOT" "$KERNEL" "$BUSYBOX" "$DUMMY" "$UV" "$X11_DEBS" lower "$FIXED_IBUS_DEB"
```

Keep the original Debian `ibus_1.5.32-2_arm64.deb` beside the test archive. Passing the fixed archive enables a strict one-menu, one-contact, one-IBus-event acceptance check and restores the Debian package in the disposable guest after the desktop exits.
