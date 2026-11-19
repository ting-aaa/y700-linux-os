# Chromium touchscreen gestures

The PRC Y700 touchscreen uses the Novatek NT36523N SPI driver. Its evdev interface declares ten direct Type-B slots, `BTN_TOUCH`, native X and Y ranges of 0–16000 and 0–25600, contact width and pressure. The raw axes stay in portrait orientation. The device tree supplies sizes 16001 and 25601 with no axis swap or inversion. [Pinned touch driver](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0003-asphalt-touch.patch#L1172-L1273) · [Pinned board device tree](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0006-asphalt-board-dts.patch#L462)

The Xfce helper maps the touchscreen to DSI-1 through XInput. On a single full-screen output, left rotation maps raw normalized `(x, y)` to `(1-y, x)`. The four-orientation test gives a QEMU-only DRM VKMS connector the board's DSI-1 name so the installed `y700-display --rotate` operates on a RandR CRTC. The test keeps a single 1600×2560 mode and lets the CRTC swap the desktop bounds for either landscape orientation. Xorg receives the simulated touchscreen through its normal libinput driver. [Board X11 helper](../src/session/y700-display) · [XInput rotation matrix](https://gitlab.freedesktop.org/xorg/app/xinput/-/blob/xinput-1.6.4/src/transform.c#L136)

Chromium tracks the focal point of the contacts for panning and also tracks their separation for pinching. The test moves both contacts upward without changing their separation, then spreads the contacts in place. It checks the document's scroll offset independently from `visualViewport.scale` and `devicePixelRatio`. The fixture uses the browser's default `touch-action` and only observes DOM state. A website can constrain browser gestures through its own `touch-action` declaration. [Chromium gesture detector](https://github.com/chromium/chromium/blob/156.0.8078.47/ui/events/gesture_detection/gesture_detector.cc) · [Pointer Events `touch-action`](https://www.w3.org/TR/pointerevents3/#the-touch-action-css-property)

## Four-orientation gesture checks

The test first uses `EVIOCGABS` to verify the simulated device exposes the native single-touch and multitouch axis ranges and ten slots. It sends the same off-centre contact at native coordinates (3920, 16896) in each orientation. Chromium must report a trusted touch at the expected normalized point and a touch-derived click on the matching HTML button. The browser expectations are fixed separately from the injected traces, and the test never uses the observed XInput matrix to generate coordinates.

For the swipe, Chromium must initially see two touches at normalized (0.34, 0.73) and (0.48, 0.73), then scroll more than 80 CSS px at page scale 1. For the spread, it must see two touches at (0.48, 0.47) and (0.66, 0.47), then show at least 1.25× page scale and maintain document scroll within 2 CSS px. The test checks the two contact positions individually and verifies the CSS viewport, device pixel ratio, and Chromium renderer sandbox.

## Dev10 result at 200%

The sealed 1,112-package dev10 root and Y700 `7.3.4-asphalt-prc` kernel passed all twelve browser actions. Xorg modesetting rotated the VKMS DSI-1 CRTC through the packaged `y700-display --rotate` command and the corresponding XInput mapping. The guest ran Chromium 156.0.8078.47 as `y700`, with seccomp filtering, `NoNewPrivs=1`, and a distinct renderer PID namespace in each orientation.

| Active RandR orientation | CSS viewport | Observed normalized tap | Scroll at page scale 1× | Pinch with unchanged scroll |
| --- | ---: | ---: | ---: | ---: |
| Normal | 800×1280 | (0.2444, 0.6598) | +520.5 px | 2.48× |
| Left | 1280×800 | (0.3398, 0.2444) | +361.5 px | 2.65× |
| Inverted | 800×1280 | (0.7550, 0.3398) | +524.0 px | 2.48× |
| Right | 1280×800 | (0.6598, 0.7550) | +347.5 px | 2.65× |

Chromium reported DPR 2 and a trusted touch-derived button click in all four directions. Replaying the recorded browser results with a wrong coordinate, wrong button or mouse-derived click made the corresponding assertion fail. This test covers the packaged rotation command and the evdev-to-browser path. Physical panel scanout, NT36523N contact tracking and gesture comfort on the glass require on-device measurement.

## Earlier dummy-display measurements

Chromium 156.0.8078.47 on the dev8 Debian ARM64 root received both contacts through `uinput` → evdev → Xorg libinput → XI2. Xorg reported a direct-touch device with a 10-contact maximum. The page saw the expected normalized start centroid of about `(0.50, 0.73)` for scrolling and `(0.50, 0.47)` for pinching in both orientations. The renderer had a separate PID namespace, seccomp filtering and `NoNewPrivs=1` in each run.

| Virtual display | Two-finger swipe, document movement | Spread two fingers, viewport scale | Device pixel ratio |
| --- | ---: | ---: | ---: |
| 1600×2560 portrait | +1,065 CSS px | 1.00× → 3.87× | 1 |
| 2560×1600 left landscape | +854 CSS px | 1.00× → 4.00× | 1 |

The swipe kept viewport scale at 1×. The spread preserved the document scroll offset in each run. [Dev8 root receipt](BOARD-IMAGE.md#dev8-first-login-keyboard-image)

The dev9 image with qcam revision y7002 ran the same browser and two-contact traces at the tablet's 200% Xfce setting. Chromium used its window manager's kiosk bounds. The fixture waited until the page had loaded, had focus and had received eight animation frame callbacks before sending the first touch. Both orientations reported the expected centroids, four touch starts across the two gestures, and an isolated, seccomp-filtered renderer.

| Virtual display | Browser viewport in CSS px | Two-finger swipe, document movement | Spread two fingers, viewport scale | Device pixel ratio |
| --- | ---: | ---: | ---: | ---: |
| 1600×2560 portrait | 800×1280 | +602.5 CSS px | 1.00× → 2.94× | 2 |
| 2560×1600 left landscape | 1280×800 | +320 CSS px | 1.00× → 3.72× | 2 |

The page scale again stayed at 1× during the swipe and the scroll offset stayed fixed during the spread. A second dev9 boot reproduced both pinch factors to two decimals and scrolled +520 CSS px in portrait and +330.5 CSS px in landscape. The dev8 regression also passed in both orientations. Physical contact tracking, two-finger motion and gesture comfort on the glass still require testing. [Dev9 image receipt](BOARD-IMAGE.md#dev9-image-with-the-scaled-qcam-chooser)

## Reproduce in ARM64 QEMU

Use a verified dev9 or dev10 ARM64 QCOW2 root with its backing chain available, the matching Y700 candidate `Image` and prepared kernel tree, an ARM64 static BusyBox, and an ARM64 `uv`. The fixture starts xfsettingsd with the packaged tablet profile and verifies the GTK scale before launching Chromium. It serves the web page over guest loopback without a virtual network interface. The root disk is attached read-only and browser profiles reside in the guest's temporary overlay. The test uses software rendering throughout.

Build the guest-only VKMS module with an empty output directory. The build uses a private mount namespace, a read-only prepared kernel tree and the LLVM ARM64 toolchain.

```sh
bash tests/touch-gestures/build-vkms.sh "$prepared_kernel" "$empty_output_dir"
VKMS_MODULE="$empty_output_dir/vkms.ko" \
  bash tests/touch-gestures/run-qemu.sh "$root_qcow2" "$kernel" "$busybox" "$arm64_uv"
```

For the dummy-display variant, supply the Debian ARM64 `xserver-xorg-video-dummy` archive `1:0.4.0-1+b2`. The fixture verifies its SHA-256. In this variant it switches modes and applies an explicit XInput matrix for each direction. The dev8 root uses its original 100% profile.

```sh
bash tests/touch-gestures/run-qemu.sh "$root_qcow2" "$kernel" "$busybox" "$arm64_uv" "$dummy_deb"
```

The script requires GNU coreutils, Bash, `aarch64-linux-gnu-gcc`, cpio, gzip and `qemu-system-aarch64`. It checks for sandboxed renderer processes and launches Chromium under the ordinary `y700` account. Linux must provide unprivileged user namespaces. The ARM64 initrd uses `switch_root` into a writable overlay over the read-only Debian disk so Chromium can create its normal sandbox there. The injector will not create a uinput device outside a guest booted with the fixture marker. [Debian dummy display driver](https://packages.debian.org/trixie/xserver-xorg-video-dummy)
