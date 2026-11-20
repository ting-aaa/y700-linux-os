# Automatic rotation and direct touch on ARM64

Run on Linux with QEMU AArch64, a cross-compiler for the ARM64 evdev fixture, the compiled Y700 kernel and its LLVM build tools, a static ARM64 BusyBox, and ARM64 `uv`. Prepare the DSI-capable VKMS module with [the existing gesture fixture](../../docs/TOUCH-GESTURES.md#reproduce-in-arm64-qemu). Use the checksum-pinned libssc 0.4.4 upstream archive and the same ARM64 protobuf and libqrtr build root as [the SSC desktop fixture](../ssc-desktop/run.sh). Protobuf preparation uses a private mount namespace and requires root on the test host.

```sh
bash tests/rotation-touch/run-qemu.sh \
  "$dev12_4_root_qcow2" "$kernel_build" "$vkms_module" \
  "$libssc_orig_tarball" "$arm64_build_root" "$arm64_busybox" "$arm64_uv"
```

The disk and its backing chain are opened read-only. All guest writes go to a disposable RAM overlay. The VM has no network interface or passthrough devices. The guest starts an ordinary local `y700` PAM session on seat0 and runs the installed rotation autostart command. The stock Polkit policy applies to the installed SensorProxy process. The proxy is started directly because the packaged unit depends on the actual SLPI service.

Set `SSC_DESKTOP_PROBE` to `scripts/trial-ssc-desktop.py` to exercise the same noninteractive desktop sensor client as the physical trial, before applying any rotation.

The gravity vectors pass through the upstream SSC QMI mock, kernel QRTR transport, installed libssc and installed SensorProxy. The test changes the mock accelerometer dataset in place and checks the reported orientation independently of RandR. It verifies the locked-by-default preference, the four real DSI-1 rotations, and that a flat pose leaves rotation unchanged. For each orientation, the same off-centre raw contact follows uinput, evdev, Xorg libinput and XInput mapping into a screen-sized GTK application's direct touchscreen event at 200% scale. The window is unmanaged to keep the measurement independent of the window manager. The expected normalized screen coordinates come from the existing independent touch oracle.

Pass requires `ROTATION_GUEST_EXIT=0`, `Y700_SSC_ROTATION_TOUCH_PASS` and four matching orientation and touch records. This exercises the installed software pipeline with virtual hardware and synthetic gravity. Physical sensor axes, panel timing, touchscreen glass, and SLPI power management remain device-level checks.
