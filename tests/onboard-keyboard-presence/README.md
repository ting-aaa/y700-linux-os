# Onboard with external input devices

Run on a Linux PC with an ARM64 QEMU installation, Bash, `cpio`, `gzip`, and an AArch64 cross compiler. Supply the sealed product QCOW2, its matching Y700 kernel `Image`, the QEMU-only DSI [VKMS module](../touch-gestures/build-vkms.sh), static ARM64 BusyBox and ARM64 uv. Set `QEMU_SYSTEM_AARCH64` and `QEMU_DATA` to use a private QEMU installation, or `AARCH64_CC` to select a different cross compiler.

```sh
bash tests/onboard-keyboard-presence/run.sh \
    root.qcow2 Image vkms.ko busybox-arm64 uv-arm64
PLATFORM_DEB=./y700-platform_0.1.0~dev12.5_all.deb \
    bash tests/onboard-keyboard-presence/run.sh \
    root.qcow2 Image vkms.ko busybox-arm64 uv-arm64
```

Set `ONBOARD_DEB` to an ARM64 `onboard` candidate archive to test the exact packaged application. Set `ONBOARD_PROFILE=external-off` to save an explicit detection opt-out on the base root before either package upgrade and check it in the next Xfce session. The fresh enabled-default run also checks that live toggles update a focused entry immediately while the keyboard stays attached and keep Onboard hidden when no text entry is focused.

The fixture starts the packaged Xfce session and Onboard autostart with a fresh profile in a local `y700` PAM session at 200%. It focuses a regular GTK entry using GTK's focus API by default. Set `ONBOARD_FOCUS=touch` to use direct Type-B contacts through the kernel, libinput and Xorg. In either mode, the fixture requires the application to observe active input focus and Onboard to report its stable `Visible` state through D-Bus. Independent keyboard and mouse descriptors use the kernel's UHID and HID drivers. The test requires real udev input classifications, Bluetooth bus type and Xorg presence before checking Onboard.

With detection enabled by the installed package, mouse-only attachment keeps automatic show available. A keyboard hides Onboard while editing and keeps it hidden on newly focused fields. Unplugging that keyboard brings Onboard back even with the mouse still attached. Explicit user overrides for keyboard detection and auto-show are checked separately. The stock test also records the pre-change behavior with detection disabled.

The base disk is read-only. Package installation and test user state live in a disposable RAM overlay. The guest has no external network or hardware passthrough. The fixture verifies the input stack from emulated devices through the desktop. Pairing and radio transport have separate [virtual Bluetooth tests](../../docs/BLUETOOTH-VIRTUAL.md).
