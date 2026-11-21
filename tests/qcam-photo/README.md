# qcam photo QA

With Qt 6 Widgets and the libcamera 0.7.2 development files installed, run `bash tests/qcam-photo/run-focus-button.sh` to exercise the production focus button at 200% scale. The test uses synthetic control lists in an offscreen Qt session. It checks the initial preview, one start or cancel per tap, late frames, focus and error feedback, a camera switch, and the Chinese labels. The three virtual cameras in the shutter test below also exercise the fixed-focus path in the full application.

With the tablet photo patch applied to the libcamera 0.7.2 source, run the store test on Linux with a C++20 compiler, `pkg-config`, Qt6 Core and Gui development packages, and the Qt6 JPEG plugin.

```sh
bash tests/qcam-photo/run.sh "$patched_libcamera"
```

The test creates a new Pictures directory, decodes every JPEG from five sequential and eight concurrent saves, and checks that earlier files remain unchanged. A 512-byte process file limit forces a real write error. The fixture observes file creation as well as the final directory listing and checks that saving works again after restoring the limit.

For the shutter test, use the Y700 ARM64 kernel, a disposable dev12.4-or-later root with the Qt desktop packages, the reviewed Y700 qcam archive, a static ARM64 BusyBox and ARM64 uv. Put the exact `libcamera0.7` 0.7.2-1 runtime closure from signed Debian Sid and Trixie APT metadata in a separate directory. Versions and checksums are listed in [virtual-runtime.sha256](virtual-runtime.sha256). The X11 archive directory must contain ARM64 `xvfb`, `xdotool` and `libxdo3`.

```sh
fixture=$(realpath tests/qcam-photo)
(cd "$virtual_runtime_debs" && sha256sum --strict -c "$fixture/virtual-runtime.sha256")
bash tests/qcam-photo/run-virtual-qemu.sh \
  "$root_qcow2" "$kernel_image" "$qcam_deb" "$virtual_runtime_debs" "$x11_debs" \
  "$arm64_busybox" "$arm64_uv"
```

The runner boots an offline ARM64 guest with its root disk read-only. The test-only library registers three synthetic cameras under the board's libcamera IDs. Their sources are moving colour bars at 800×600, diagonal stripes at 640×480 and a generated red/green image at 320×240. A fourth synthetic external camera shares the main camera's address suffix to check that its name stays unchanged.

At 200%, the verifier uses AT-SPI to locate widgets and sends X11 pointer clicks to the toolbar, chooser, list row, confirmation and shutter. One process takes photos in main, front, macro and main order. Each save must add exactly one complete JPEG. The verifier checks its dimensions and pixel pattern, checks that preview continues and removes all four files. The `y7004` checks also require the chooser to remember the active lens and its controls to measure at least 96 device pixels high. Set `QCAM_VIRTUAL_LANGUAGE=zh` to exercise the Chinese UI. There is no hardware passthrough.
