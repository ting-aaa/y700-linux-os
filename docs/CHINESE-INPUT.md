# Chinese input with Onboard

Tap the input-language icon in the Xfce panel and choose **Chinese – Intelligent Pinyin**. Tap the text field to bring up Onboard, then tap the letters for the syllables you want. Tap the number beside the desired candidate in the popup. In the test, the first tap sometimes left the composition unchanged. A second tap on the same visible candidate completed it. The Onboard Space key also committed the highlighted candidate. To switch back, choose **English – English (US)** from the panel and continue typing with Onboard.

## Measured desktop path

The isolated ARM64 test starts an ordinary `y700` session through Debian Xsession and the shipped Xfce autostart. It uses the shipped 200% profile on a private 2560×1600 X11 display. Debian Xsession supplies the IBus GTK module and XIM setting. The test uses the stock IBus panel and the bundled Compact Onboard layout. [Test entry point](../tests/chinese-input/run-arm64.sh)

The test first taps from a non-editable GTK control into the empty text field. Five pointer taps on Onboard produce `nihao` and the real libpinyin popup. The application still reports empty committed text while the candidate is visible. The probe checks that the popup owns the candidate click, then requires the application itself to report committed `你好` and an empty preedit. Switching to English through the same tray menu and typing on Onboard leaves the field with exactly `你好 hello`. A Space fallback is recorded separately and cannot pass the popup-tap gate. [Application and popup assertions](../tests/chinese-input/probe.py)

Both placements passed on the final 1,112-package dev9 image with `y700-input-pinyin 0.1.0~dev3`. The upper popup was at `804,548` and clear of the keyboard. The lower popup was at `804,816` and overlapped the keyboard. XQueryPointer identified IBus as the input window in both cases. The first numbered tap left the preedit unchanged, and the second emitted `CandidateClicked(0, 1, 0)` on the private IBus bus and committed the phrase. The cause of the first missed tap remains open. The probe chooses the tray menu nearest the tray icon when IBus draws two copies. [IBus candidate click implementation](https://github.com/ibus/ibus/blob/1.5.32/ui/gtk3/candidatearea.vala#L244-L270)

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

The tests use synthetic X11 pointer clicks. Finger input through the tablet digitizer and candidate interaction on the physical panel remain to be checked.
