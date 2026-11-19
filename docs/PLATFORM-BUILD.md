# Repaired desktop integration milestone

The offline integration procedure below targets a disposable ARM64 root directory. For package-only changes, install the reviewed package on the connected Debian tablet and carry the same package into the image inputs. The physical package check is sufficient for that change; building or booting the whole image is a separate task.

## Connected tablet package check, 2026-11-18

The installed tablet matched all 30 repair package versions. An APT simulation selected only `y700-platform 0.1.0~dev2`. The installed archive matched the candidate 03 package SHA-256, `25519c8c72ed762e68765378372c127b9252f04eaf30d20b3281a09b490f6972`. Before installation we checked package file ownership, archived the existing Chromium policy and the two known user autostart entries, and prepared an uninstall-and-restore script under `/var/backups/y700-platform-live/`. The package provides matching keyboard and touch startup entries for the next login. Chromium kept the same GPU option.

On the tablet, package integrity, dpkg audit and APT dependency checks passed. A fresh SSH connection succeeded. The boot ID and existing SSH, USB and LightDM service invocations matched their pre-install values. The live Xfce session reported a 64-pixel panel, 40-pixel icons, compositing disabled, one Onboard process with automatic show enabled and portrait/landscape dock heights of 520/420. X11 recognized the touchscreen. The existing maintenance configuration continued to serve the connection. These observations cover the running session; the new autostart entries take effect on a future login.

## Package build and checks

```sh
bash scripts/build-platform.sh
bash tests/platform-package.sh
uv run --python 3.13 --no-project python -m unittest discover -s tests -v
```

Requirements include Bash, GNU coreutils, findutils, dpkg-deb, xz and uv. The package contains architecture-independent scripts and configuration. Its runtime dependencies are resolved in the ARM64 candidate. Repeated builds with the same `SOURCE_DATE_EPOCH` are compared byte-for-byte. By default the epoch is the Git commit timestamp. Source archives without Git metadata must supply an explicit valid epoch. Future epochs are rejected to protect the early-boot clock. This establishes determinism of the package on the tested builder.

The package includes X11 touch alignment, Onboard/Xfce defaults, the temporary Chromium/compositor workaround, USB ACM/NCM, the dedicated maintenance SSH service and optional Bluetooth controller address provisioning. The offline image builder enables service ordering. The package installs the unit files for local activation. `y700-onboard.desktop` has its own name to avoid replacing Debian's Onboard-owned autostart file. The session defaults are applied once per user; touch alignment still starts if settings initialization fails.

The USB descriptor class and function combination follow the repaired prototype. Serial and locally administered MAC addresses are generated separately per installation. Host recognition of those new identities is **not physically tested**. The current tablet continues using its existing tested maintenance service.

## Tablet display scale

From the Xfce applications menu, open **Settings → Tablet display scale**. Select **200% Larger controls** for touch or **100% Standard** to restore the standard desktop scale. Both choices apply immediately through Xfce's user XSettings. Reopen apps that keep their old size.

The launcher writes the current user's `xsettings:/Gdk/WindowScalingFactor` when a scale is selected. The option applies to the signed-in X11 desktop and compatible apps across all connected displays. Xfce Appearance uses the same setting for its 1× and 2× options. [Xfce 4.20.1 source](https://github.com/xfce-mirror/xfce4-settings/blob/xfce4-settings-4.20.1/dialogs/appearance-settings/main.c)

In a disposable Debian 13 ARM64 root with Xfce 4.20.1, X11 clicks through the installed launcher changed the scale from 1× to 2× and back in both 1600×2560 and 2560×1600 sessions. Thunar's window went from 640 to 1280 and back to 640 pixels in each run. To reproduce, install the package with Xvfb and xdotool in a disposable desktop environment and run `bash tests/tablet-scale-x11.sh` and `bash tests/tablet-scale-x11.sh 2560x1600`. Chromium, Onboard and touch usability on the physical tablet remain to be tested.

## Bluetooth controller address

Version `0.1.0~dev5` supplies the controller's original public address from `/etc/y700/bluetooth-address` when BlueZ reports it missing on Asphalt's WCN6855 Bluetooth controller. The helper needs a root-owned private address file. The unit runs before BlueZ and the built image expects per-device provisioning after installation.

BlueZ can exit on stdin EOF even when given a command. The helper keeps stdin open for its short management command timeout and checks the controller's reported address after programming. Run `sudo bash tests/bluetooth-identity.sh` on a usr-merged Linux host with bubblewrap to exercise the board match, file permissions, noninteractive command path, handling of existing addresses and failed readback in an isolated fixture. Physical discovery and HID acceptance have separate checks. [Bluetooth notes](PERIPHERALS.md)

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
| First-boot UX | Historical console password setup remains; touch-only graphical enrollment/login is not implemented |
| Image identity finalization | Remove build host keys, machine ID, cached credentials and private logs; provision a new user/identity before any distribution |
| Saved rotation | Current left rotation was physically accepted; package follows chosen Xfce rotation and does not force a direction |
| Runtime | New login/cold boot, Onboard auto-show, newly provisioned USB identity and actual SSH authentication require attended tests |

The fresh candidate still contains build-generated state requiring finalization. Earlier copied-root candidates also contain historical base state. These are private test materials, **not distributable images**. The old `reference/` image packager remains historical and must not be used to bypass these gates.
