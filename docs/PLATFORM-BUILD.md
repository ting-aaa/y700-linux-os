# Repaired desktop integration milestone

The offline integration procedure below targets a disposable ARM64 root directory. For package-only changes, install the reviewed package on the connected Debian tablet and carry the same package into the image inputs. The physical package check is sufficient for that change; building or booting the whole image is a separate task.

## Connected tablet package check, 2026-11-18

The installed tablet matched all 30 repair package versions. An APT simulation selected only `y700-platform 0.1.0~dev2`. The installed archive matched the candidate 03 package SHA-256, `25519c8c72ed762e68765378372c127b9252f04eaf30d20b3281a09b490f6972`. Before installation we checked package file ownership, archived the existing Chromium policy and the two known user autostart entries, and prepared an uninstall-and-restore script under `/var/backups/y700-platform-live/`. The package provides matching keyboard and touch startup entries for the next login. Chromium kept the same GPU option.

On the tablet, package integrity, dpkg audit and APT dependency checks passed. A fresh SSH connection succeeded. The boot ID and existing SSH, USB and LightDM service invocations matched their pre-install values. The live Xfce session reported a 64-pixel panel, 40-pixel icons, compositing disabled, one Onboard process with automatic show enabled and portrait/landscape dock heights of 520/420. X11 recognized the touchscreen. The existing maintenance configuration continued to serve the connection. These observations cover the running session; the new autostart entries take effect on a future login.

## Rotation package update, 2026-11-19

The same physical PRC tablet upgraded from platform dev6 to dev7 over USB SSH. APT selected one upgrade. The boot ID and the LightDM, SSH and Bluetooth service invocations matched before and after installation. The actual desktop user's dconf preference read `false` on a fresh SSH connection. The tablet remained at its ordinary greeter with SLPI offline. The packaged Xfce autostart begins on the next desktop login. The local rollback archive restores dev6.

The dev7 archive SHA-256 is `484f2ba489f59423d4d10daa5f75b6916c6f44dbf3f0a2d2df8e606583b4d0ae` at build epoch `1794969749`. Applying it to a private overlay of the combined KMS root ran the stock GLib trigger and matched the full 1,069-package set, digest `11dbe979be7212b2a36285ef0cee0a72bada9b64b0c26c557d3684135dc543f1`. Downgrading to dev6 in that overlay restored the original package and removed the rotation client. The downloadable local raw image still contains dev6. [Rotation behavior and tests](CAMERA-SENSORS.md#xfce-screen-rotation)

## Onboard accessibility update, 2026-11-19

Touchscreen enrollment followed by the first Xfce desktop sign-in on dev7 showed Onboard's accessibility confirmation. Onboard checks `org.gnome.desktop.interface toolkit-accessibility` when auto-show is enabled. Dev8 compiles that setting and the tablet's Onboard preferences as Xfce-specific GSettings defaults. They are available when the desktop starts, and saved per-user GSettings values take precedence. [Onboard 1.4.1-10 accessibility check](https://sources.debian.org/src/onboard/1.4.1-10/Onboard/Config.py/#L1140)

The physical PRC tablet upgraded to `0.1.0~dev8` with a single package transaction and the standard GLib trigger. Using an empty preferences backend as the ordinary account, the device reported `toolkit-accessibility=true` for Xfce and `false` for GNOME. The tablet stayed at the ordinary sign-in screen with the same boot and USB, SSH, LightDM and BlueZ service invocations. The drive retains the prior dev7 package for rollback. The deterministic dev8 archive SHA-256 is `840bf029136b287b0f71de2f216603855f10337c999af32d1097ed796e478bac` at build epoch `1795092371`.

In a disposable Debian 13 ARM64 X11 session, Xfce started Onboard through its packaged autostart without a confirmation dialog. Focusing Thunar's address bar showed the keyboard and closing Thunar hid it. A separate session preserved explicit choices for accessibility, automatic show, startup visibility and dock height. Reproduce with the installed package, Xvfb and xdotool by running `bash tests/onboard-xfce-x11.sh fresh` and `bash tests/onboard-xfce-x11.sh opt-out` as an ordinary user.

## Package build and checks

```sh
bash scripts/build-platform.sh
bash tests/platform-package.sh
uv run --python 3.13 --no-project python -m unittest discover -s tests -v
```

Requirements include Bash, GNU coreutils, findutils, dpkg-deb, xz, glib-compile-schemas and uv. The package contains architecture-independent scripts and configuration. Its runtime dependencies are resolved in the ARM64 candidate. Repeated builds with the same `SOURCE_DATE_EPOCH` are compared byte-for-byte. By default the epoch is the Git commit timestamp. Source archives without Git metadata must supply an explicit valid epoch. Future epochs are rejected to protect the early-boot clock. This establishes determinism of the package on the tested builder.

The package includes X11 touch alignment, Onboard/Xfce defaults, the temporary Chromium/compositor workaround, USB ACM/NCM, the dedicated maintenance SSH service and optional Bluetooth controller address provisioning. The offline image builder enables service ordering. The package installs the unit files for local activation. `y700-onboard.desktop` provides the Onboard autostart for Xfce. The Xfce session prepares panel size settings once per user. Touch alignment starts even if that initialization fails.

The USB descriptor class and function combination follow the repaired prototype. Serial and locally administered MAC addresses are generated separately per installation. Host recognition of those new identities is **not physically tested**. The current tablet continues using its existing tested maintenance service.

## Tablet display scale

Platform dev9 selects a 200% starting scale for Xfce when the Lenovo Asphalt device tree is present and DSI-1 is the sole active output at its native 1600×2560 resolution in either orientation. At 200% this gives compatible apps an 800×1280 portrait or 1280×800 landscape workspace in logical pixels. The system uses the active mode for this decision because the stock Xorg driver drops the panel's physical dimensions. A session starting with an active external display uses its ordinary Xfce defaults. [Panel measurements](PANEL-GEOMETRY.md)

Debian's Xsession hook adds a one-property Xfconf profile before startup. Xfconf merges the system channels in XDG search order and then reads the user's saved values. A saved integer scale takes priority. Older profiles containing an empty scale property inherit the board default. [Xfconf 4.20 merge implementation](https://github.com/xfce-mirror/xfconf/blob/xfconf-4.20.0/xfconfd/xfconf-backend-perchannel-xml.c#L1681-L1724)

A single-package upgrade to dev9 on the PRC tablet preserved the running boot and service invocations. Reading its actual DSI topology and loading an isolated ordinary-user Xfconf profile returned scale 2. In Debian ARM64, four new X11 sessions using real GTK and Thunar measured 1280 physical pixels of window width with the tablet profile or a legacy empty value, and 640 with an explicit 100% setting or the standard system profile. A verified dev8 archive is retained for downgrade. The dev9 package SHA-256 is `a1e1fa923877ecbc60963814bed6811bf3544c05f9fdab7fb5689c976f57d0e4` at epoch `1795095900`. Run `bash tests/tablet-xsession-scale.sh` and `bash tests/tablet-scale-default-x11.sh` with the installed package to reproduce the selector and window tests.

From the Xfce applications menu, open **Settings → Tablet display scale**. Select **200% Larger controls** for touch or **100% Standard** to restore the standard desktop scale. Both choices apply immediately through Xfce's user XSettings. Reopen apps that keep their old size.

The launcher writes the current user's `xsettings:/Gdk/WindowScalingFactor` when a scale is selected. The option applies to the signed-in X11 desktop and compatible apps across all connected displays. Xfce Appearance uses the same setting for its 1× and 2× options. [Xfce 4.20.1 source](https://github.com/xfce-mirror/xfce4-settings/blob/xfce4-settings-4.20.1/dialogs/appearance-settings/main.c)

In a disposable Debian 13 ARM64 root with Xfce 4.20.1, X11 clicks through the installed launcher changed the scale from 1× to 2× and back in both 1600×2560 and 2560×1600 sessions. Thunar's window went from 640 to 1280 and back to 640 pixels in each run. To reproduce, install the package with Xvfb and xdotool in a disposable desktop environment and run `bash tests/tablet-scale-x11.sh` and `bash tests/tablet-scale-x11.sh 2560x1600`. Chromium, Onboard and touch usability on the physical tablet remain to be tested.

The optional warm-greeter layer adds an on-screen keyboard to ordinary LightDM sign-in. [Build and VM verification](WARM-GREETER.md)

## Bluetooth controller address

Version `0.1.0~dev5` supplies the controller's original public address from `/etc/y700/bluetooth-address` when BlueZ reports it missing on Asphalt's WCN6855 Bluetooth controller. The helper needs a root-owned private address file. The unit runs before BlueZ and the built image expects per-device provisioning after installation.

BlueZ can exit on stdin EOF even when given a command. The helper keeps stdin open for its short management command timeout. The kernel acknowledges the address command before its worker programs the controller. The follow-up to dev5 sends one write command and polls `info` for confirmation within a bounded retry budget. Run `sudo bash tests/bluetooth-identity.sh` on a usr-merged Linux host with bubblewrap to exercise the board match, file permissions, noninteractive command path, handling of existing addresses, delayed confirmation and failure after exhausted retries in an isolated fixture. Physical discovery and HID acceptance have separate checks. [Bluetooth notes](PERIPHERALS.md) [Linux `set_public_address`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/net/bluetooth/mgmt.c?h=v7.3.4#n8376) [HCI configuration worker](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/net/bluetooth/hci_sync.c?h=v7.3.4#n5352)

## Locked repair archives and offline integration

`config/desktop-repair.lock.json` records the 30 archives used by the deployed repair, including exact name, version, architecture, length and SHA-256. These were originally obtained from verified Debian repository metadata. Obtain matching versions from authenticated Debian repositories/archive services; the lock verifies bytes but does not replace signature verification. Do not silently substitute newer versions or treat the lock as the entire base distribution lock.

```sh
uv run --python 3.13 --no-project python scripts/repair-inputs.py verify /build/repair-debs config/desktop-repair.lock.json
# Build and configure /build/candidate using DEBIAN-SNAPSHOT.md first.
# That builder writes the disposable-root marker after checking all packages.
sudo env UV_BIN=/path/to/uv bash scripts/integrate-rootfs.sh \
  /build/candidate /build/repair-debs out/packages/y700-platform_0.1.0~dev5_all.deb
sudo env UV_BIN=/path/to/uv bash tests/arm64-rootfs.sh /build/candidate
```

The Linux host needs working ARM64 binfmt/QEMU user emulation, mount namespaces and root privileges. Set `UV_PYTHON` to an available uv-managed version (3.12 and 3.13 were used in development). Integration mounts proc and read-only sys in a private mount namespace; package service starts are denied. It audits dpkg/APT, disables the historical USB services, masks distribution SSH service/socket activation, and enables the dedicated product units offline. It records the installed package inventory inside the candidate. Existing Xfce compositing configuration is disabled before a candidate desktop can start.

The runtime check generates a temporary client key/overlay, runs ARM64 `sshd -t/-T`, validates the effective listener, allowed user and authentication policy, and confirms persistent per-install host-key generation. It removes its test credentials afterward. It does not start a listener or USB gadget. ARM64 gsettings round-trip and systemd unit parsing are also checked; QEMU user emulation does not test board boot or the kernel.

Timesyncd is enabled and its early-boot clock seed is advanced to the package build epoch if older; a newer seed is preserved. Actual clock accuracy still requires successful NTP. See the [verification receipt](VALIDATION-20261118.md) and [pending attended tests](ATTENDED-TESTS.md).

## Private installation identity

```sh
uv run --python 3.13 --no-project python scripts/provision-maintenance.py \
  --output /build/private-overlay --device-cidr 192.0.2.1/24 \
  --host-address 192.0.2.2 --user y700 --public-key /private/client.pub
```

The documentation addresses above are examples. Choose a dedicated USB subnet that does not conflict with host routes. Output must be new and stays private. Only an ED25519 **public** key is accepted. The intended user must already exist. SSH is key-only, denies root, restricts the host address and disables forwarding; it uses its own configuration instead of inheriting permissive distribution drop-ins. Its host key is generated at first service start and must be authenticated and pinned before connecting. Generating this overlay is not proof of a successful login or a recovery route.

## Remaining build/release gates

| Input or behavior | Current boundary |
| --- | --- |
| Debian base root | The 994-package dev5 root passed ARM64 integration and UFS-layout QEMU verification. The historical signed snapshot needs a security refresh. [Image verification](BOARD-IMAGE.md#dev5-ufs-layout-check-2026-11-19) |
| Kernel/DT/initramfs | Historical pinned recipe; no new kernel/image rebuilt by this milestone |
| Board firmware | Local provenance retained; missing sensor firmware and redistribution review remain |
| Boot-success marking | Existing board lifecycle is not modified by this package; no new slot-success writer is introduced |
| First-boot UX | The optional framebuffer keyboard passed touchscreen-only enrollment through `passwd` and PAM in an ARM64 VM. The optional Arctica greeter passed password entry and logout using its embedded keyboard. Physical touch alignment, readable controls and the transition between both screens remain open. [First local password](FIRSTBOOT-TOUCH.md) |
| Image identity finalization | Remove build host keys, machine ID, cached credentials and private logs; provision a new user/identity before any distribution |
| Saved rotation | Current left rotation was physically accepted; package follows chosen Xfce rotation and does not force a direction |
| Runtime | New login/cold boot, Onboard auto-show, newly provisioned USB identity and actual SSH authentication require attended tests |

The fresh candidate still contains build-generated state requiring finalization. Earlier copied-root candidates also contain historical base state. These are private test materials, **not distributable images**. The old `reference/` image packager remains historical and must not be used to bypass these gates.
