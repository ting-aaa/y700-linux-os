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
  /path/to/blueman_2.4.4-1_arm64.deb out/blueman-pairing-offline y7001
```

The test runner uses a read-only qcow2 root, private Linux mount, network and PID namespaces, and ARM64 binfmt emulation on x86. Provide host `qemu-nbd` and `nbdfuse` in the same directory, Debian ARM64 Xvfb, xdotool and libxdo3 archives, Debian `python3-dbusmock` 0.38.1-1 and an ARM64 `uv` executable. The runner requires the qcow2 leaf's SHA-256 and the original backing chain at its declared paths. Omit the final two arguments to run the stock control and reproduce its index error. [Runner](../tests/blueman-pairing/run-arm64.sh)

```sh
sudo bash tests/blueman-pairing/run-arm64.sh \
  "$ROOT_QCOW2" "$ROOT_SHA256" "$NBD_BIN_DIR" "$X11_DEB_DIR" "$DBUSMOCK_DEB" "$ARM64_UV" \
  out/blueman-pairing-offline/blueman_2.4.4-1+y7001_arm64.deb \
  bcb0ba040878da8c82ca3a7ac83e3d6cffb1477660d9e6651dbb9271bdf8737c
```

The fixture isolates the desktop agent from host hardware and uses synthetic pairing requests and pointer clicks. The passkey flow now has an ARM64 userspace regression test. The tablet's digitizer, Bluetooth bonding and reconnect with a physical keyboard or mouse need their own checks. [Physical radio evidence](BLUETOOTH-HID-RADIO.md)

## Installed tablet software check

On 2026-11-19 the installed `2.4.4-1+y7001` package passed the same test through USB SSH on the TB320FC_PRC. The test ran the packaged applet as `y700` inside private mount, network and PID namespaces. It used a read-only view of the installed system, private display and D-Bus sessions, and a synthetic BlueZ service. The test could only see its temporary home and Bluetooth state. The active desktop kept running.

At 200% Xfce scaling on the private 2560×1600 display, the built-in GTK dialog's Confirm and Deny buttons measured 708×84 and 706×84 pixels. Both pointer clicks returned the expected replies. The applet registered `KeyboardDisplay`, displayed the matching code at 0, 3 and 6 digits entered, and dismissed the final dialog on `Cancel`. The installed package file check was clean.

The boot, Bluetooth, SSH and LightDM service invocations, active seat, desktop processes and host mounts matched before and after. No test process or staging directory remained. This establishes the installed ARM64 software path with synthetic events. Glass input, over-the-air pairing and input from a physical accessory remain separate checks. [Probe](../tests/blueman-pairing/probe.py)

## Enter a code on the tablet

If the pairing dialog asks for a code supplied by the accessory, enter it on the tablet's screen keyboard. The PIN field masks its characters. Tap the on-screen Return key to submit, including when the docked keyboard covers the bottom of the dialog. If the tablet instead displays a code for a keyboard, type that code on the external keyboard. For numeric comparison, check the two displays before confirming. [BlueZ Agent API](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.Agent.rst)

The tablet was upgraded in place to Blueman `2.4.4-1+y7002`. Only the Blueman package tuple changed. Its files, APT dependencies and dpkg state verified. A new USB session found the same boot, active seat, desktop applet processes, and BlueZ, SSH and LightDM service instances. The owner's existing applet will load the update at the next normal login. The previous archive and a checksum-checked rollback script are on the tablet.

On this tablet, an ordinary user ran the installed applet, Xfwm and Onboard on a private 2560×1600 desktop at 200%. The fixture selected keys on the visible Compact layout by pointer, including Return. The BlueZ fixture received the exact alphanumeric string for a masked PIN and the expected integer for a six-digit passkey beginning with zero. During numeric entry a second device requested a PIN. The updated applet kept the first entry window and finished the original request. When the comparison value was zero, the old applet omitted the displayed code. The updated applet showed all six zeros. Both dialogs respected the Deny button. The fixture isolated the radio, real desktop and physical display. [Tablet runner](../tests/blueman-pairing/run-tablet.sh) · [Keyboard progress and cancellation](BLUEMAN-PASSKEY-LIFETIME.md) · [Update the dev12.7 image](BLUEMAN-UPDATE.md)
