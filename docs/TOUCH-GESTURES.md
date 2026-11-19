# Chromium touchscreen gestures

The PRC Y700 touchscreen uses the Novatek NT36523N SPI driver. Its evdev interface declares ten direct Type-B slots, `BTN_TOUCH`, native X and Y ranges of 0–16000 and 0–25600, contact width and pressure. The raw axes stay in portrait orientation. The device tree supplies sizes 16001 and 25601 with no axis swap or inversion. [Pinned touch driver](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0003-asphalt-touch.patch#L1172-L1273) · [Pinned board device tree](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0006-asphalt-board-dts.patch#L462)

The Xfce helper maps the touchscreen to DSI-1 through XInput. On a single full-screen output, the left-rotation mapping takes raw normalized `(x, y)` to `(1-y, x)`. The test applies that same XInput matrix to the virtual Xorg output and checks the two-touch centroid received by Chromium. The test uses a dummy display and the normal libinput Xorg input module. [Board X11 helper](../src/session/y700-display) · [XInput rotation matrix](https://gitlab.freedesktop.org/xorg/app/xinput/-/blob/xinput-1.6.4/src/transform.c#L136)

Chromium tracks the focal point of the contacts for panning and also tracks their separation for pinching. The test moves both contacts upward without changing their separation, then spreads the contacts in place. It checks the document's scroll offset independently from `visualViewport.scale` and `devicePixelRatio`. The fixture uses the browser's default `touch-action` and only observes DOM state. A website can constrain browser gestures through its own `touch-action` declaration. [Chromium gesture detector](https://github.com/chromium/chromium/blob/156.0.8078.47/ui/events/gesture_detection/gesture_detector.cc) · [Pointer Events `touch-action`](https://www.w3.org/TR/pointerevents3/#the-touch-action-css-property)

## Measured result

Chromium 156.0.8078.47 on the dev8 Debian ARM64 root received both contacts through `uinput` → evdev → Xorg libinput → XI2. Xorg reported a direct-touch device with a 10-contact maximum. The page saw the expected normalized start centroid of about `(0.50, 0.73)` for scrolling and `(0.50, 0.47)` for pinching in both orientations. The renderer had a separate PID namespace, seccomp filtering and `NoNewPrivs=1` in each run.

| Virtual display | Two-finger swipe, document movement | Spread two fingers, viewport scale | Device pixel ratio |
| --- | ---: | ---: | ---: |
| 1600×2560 portrait | +1,065 CSS px | 1.00× → 3.87× | 1 |
| 2560×1600 left landscape | +854 CSS px | 1.00× → 4.00× | 1 |

The swipe kept viewport scale at 1×. The spread preserved the document scroll offset in each run. These are outcomes of the synthetic traces. Actual contact detection, motion, rotation and gesture comfort on the tablet panel still require physical testing. [Dev8 root receipt](BOARD-IMAGE.md#dev8-first-login-keyboard-image)

## Reproduce in ARM64 QEMU

Use the verified dev8 ARM64 QCOW2 root with its backing chain available, the Y700 candidate `Image`, an ARM64 static BusyBox, an ARM64 `uv`, and the Debian ARM64 `xserver-xorg-video-dummy` archive `1:0.4.0-1+b2`. The fixture checks the dummy archive digest. It serves the web page over guest loopback, with no virtual network interface. The root disk is attached read-only. Temporary package files and browser profiles reside in the guest. The test uses software rendering throughout.

```sh
bash tests/touch-gestures/run-qemu.sh "$root_qcow2" "$kernel" "$busybox" "$arm64_uv" "$dummy_deb"
```

The script requires GNU coreutils, Bash, `aarch64-linux-gnu-gcc`, cpio, gzip and `qemu-system-aarch64`. It checks for sandboxed renderer processes and launches Chromium under the ordinary `y700` account. Linux must provide unprivileged user namespaces. The ARM64 initrd uses `switch_root` into a writable overlay over the read-only Debian disk so Chromium can create its normal sandbox there. The injector will not create a uinput device outside a guest booted with the fixture marker. [Debian dummy display driver](https://packages.debian.org/trixie/xserver-xorg-video-dummy)
