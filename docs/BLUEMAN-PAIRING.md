# Bluetooth pairing dialogs on the Y700 desktop

The dev9 ARM64 development image with qcam y7002 contains Debian Blueman `2.4.4-1`. Its fresh session had no active or activatable `org.freedesktop.Notifications` service. Blueman's default notification setting was enabled, so the packaged applet used its own GTK pairing dialog when it could not find a provider. The dialog worked at 200% Xfce scaling without installing `xfce4-notifyd`. [Blueman's notification selection](https://github.com/blueman-project/blueman/blob/2.4.4/blueman/gui/Notification.py)

The test starts the packaged autostart command as the unprivileged `y700` account. A stock BlueZ 5 D-Bus mock records the applet's `KeyboardDisplay` registration and request to become the default agent. The test identifies the applet's exported Agent1 by its process ID, sends independent synthetic challenges, matches zero-padded six-digit codes in its visible AT-SPI dialog, and clicks the actual buttons using X11 coordinates. The separate session bus, 2560×1600 Xvfb and real Xfce XSettings reproduce the 2× desktop scaling. [ARM64 probe](../tests/blueman-pairing/probe.py)

| Agent operation | Debian 2.4.4-1 | Local 2.4.4-1+y7001 |
| --- | --- | --- |
| Numeric confirmation | Confirm returned an empty D-Bus reply. The button measured 660×94 physical pixels. | Passed, same size. |
| Numeric denial | Deny returned `org.bluez.Error.Canceled`. The button measured 658×94 physical pixels. | Passed, same size. |
| Keyboard `DisplayPasskey`, 0 then 3 digits entered | Each request showed the matching code in a new visible dialog and returned an empty D-Bus reply. | Passed. |
| Keyboard `DisplayPasskey`, 6 digits entered | Returned `org.freedesktop.DBus.Error.Failed` with an `IndexError` from the passkey formatter. | A new dialog displayed the complete code and the agent returned an empty D-Bus reply. |
| `Cancel` | Closed the remaining passkey dialog. | Closed the completed passkey dialog. |

BlueZ's `entered` value reports how many digits the remote device has typed. Blueman 2.4.4 indexed the digit at that offset even when all six had been entered. The local patch uses a one-character slice for the next digit. At completion the slice is empty, so the dialog still shows the complete code with no next digit highlighted. [BlueZ Agent1 contract](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.Agent.rst#L83-L97) · [Source patch](../packaging/blueman/display-passkey-completion.patch)

## Build and repeat

Use the official Debian ARM64 `blueman_2.4.4-1_arm64.deb` with the [authenticated base lock](../config/debian-base.lock.json). Keep it as the rollback input. The builder applies the local source patch to that archive and updates the version and file checksum. Two builds produced the same 1,049,844-byte archive with SHA-256 `bcb0ba040878da8c82ca3a7ac83e3d6cffb1477660d9e6651dbb9271bdf8737c`. The exact ARM64 image accepted the archive through `dpkg -i` inside a disposable overlay. The only installed tuple that changed was Blueman's version. `dpkg -V blueman` and `dpkg --audit` were clean. [Build entry point](../scripts/build-blueman-passkey.sh)

```sh
mkdir -p out/blueman-pairing-offline
bash scripts/build-blueman-passkey.sh \
  /path/to/blueman_2.4.4-1_arm64.deb out/blueman-pairing-offline
```

The test runner uses a read-only qcow2 root, private Linux mount, network and PID namespaces, and ARM64 binfmt emulation on x86. Provide host `qemu-nbd` and `nbdfuse` in the same directory, Debian ARM64 Xvfb, xdotool and libxdo3 archives, Debian `python3-dbusmock` 0.38.1-1 and an ARM64 `uv` executable. The runner requires the qcow2 leaf's SHA-256 and the original backing chain at its declared paths. Omit the final two arguments to run the stock control and reproduce its index error. [Runner](../tests/blueman-pairing/run-arm64.sh)

```sh
sudo bash tests/blueman-pairing/run-arm64.sh \
  "$ROOT_QCOW2" "$ROOT_SHA256" "$NBD_BIN_DIR" "$X11_DEB_DIR" "$DBUSMOCK_DEB" "$ARM64_UV" \
  out/blueman-pairing-offline/blueman_2.4.4-1+y7001_arm64.deb \
  bcb0ba040878da8c82ca3a7ac83e3d6cffb1477660d9e6651dbb9271bdf8737c
```

The fixture isolates the desktop agent from host hardware and uses synthetic pairing requests and pointer clicks. The passkey flow now has an ARM64 userspace regression test. The tablet's digitizer, Bluetooth bonding and reconnect with a physical keyboard or mouse need their own checks. [Physical radio evidence](BLUETOOTH-HID-RADIO.md)
