# Xfce Wi-Fi chooser on Y700

On 2026-11-19, the tablet's Debian 13 session tooling opened the real NetworkManager applet in a private, cookie-authenticated Xvfb display as an ordinary user. It ran the shipped Xfce notification-area plugin, `network-manager-applet` 1.36.0-3 and the actual running NetworkManager 1.52.1-1. One synthesized pointer tap opened the tray menu and a second tap opened **Available networks**. The probe matched the showing AT-SPI menu rows to NetworkManager access-point objects in memory. [Physical probe](../tests/wifi-chooser/run-live.sh) · [Applet source](https://github.com/GNOME/network-manager-applet/blob/1.36.0/src/applet-device-wifi.c)

| Physical result | Count |
| --- | ---: |
| NetworkManager AP objects / distinct named networks | 7 / 7 |
| Active network rows in the primary menu | 1 |
| Available network rows in the submenu, verified against NetworkManager | 6 |
| Saved profiles / matching rows in the separate Network Connections editor | 2 / 2 |
| Saved profiles matching a nearby name | 1 |
| Saved profiles matching visible submenu rows | 0 |
| NetworkManager state transitions during the probe | 0 |

The active connection and saved-profile inventory matched before and after. The applet used `--no-agent`, and the physical probe did not choose any network row or edit a profile. The applet's ordinary menu event can request a scan. The X11 event targeted the private display, so the evidence covers the tray/menu click path. Finger input, digitizer mapping and physical reconnect remain separate checks. No screen image or network identifiers were emitted. The final cleanup check found zero private Xvfb processes, mounts, staging directories and run directories.

To repeat, use an existing host-key-verified SSH wrapper and a directory of matching Debian 13 ARM64 `xvfb`, `xdotool` and `libxdo3` archives. `run-live.sh` extracts the tools without installing packages and runs the temporary desktop as the existing `y700` account by default. [Session isolation](../tests/wifi-chooser/session.sh) · [Accessibility checks](../tests/wifi-chooser/probe.py)

```sh
bash tests/wifi-chooser/run-live.sh /path/to/verified-usb-ssh.sh /path/to/x11-debs
```

## Select and connect in an isolated ARM64 guest

A networkless ARM64 QEMU guest booted the exact `7.3.4-asphalt-prc` Y700 kernel and ran the real Debian NetworkManager, Xfce systray and applet. The stock upstream `mac80211_hwsim` module was built against the prepared kernel in a separate directory with the kernel tree mounted read-only. The fixture loaded it only in QEMU and used two virtual radios. A guest-owned open AP and DHCP service ran on one radio. NetworkManager managed the other. The test also supplied a saved profile for an absent synthetic network. [Module build](../tests/wifi-chooser/build-hwsim.sh) · [Guest setup](../tests/wifi-chooser/fixture-guest.sh)

The applet showed one available row. A synthesized tap on that row led to `NM_DEVICE_STATE_ACTIVATED` and a lease from the guest's DHCP range. Independent `iw` and `ip` checks confirmed association and the address. The original ping could take a local route because both radios shared a network namespace. The revised fixture runs the AP and DHCP server in a separate guest namespace, checks the route, and binds the ping to the station so traffic crosses the virtual wireless link. The guest uses a RAM-only overlay and QEMU has no external network interface. [QEMU runner](../tests/wifi-chooser/run-vm.sh)

To repeat, set `KERNEL_IMAGE`, `RAW_ROOT`, `HWSIM_MODULE`, `QEMU`, `QEMU_DATA`, `ARM64_BUSYBOX` and `ARM64_UV` to the prepared artifacts. Set `X11_DEBS` to the ARM64 archive directory used above and `WIFI_DEBS` to matching Debian 13 ARM64 `hostapd`, `iw`, `dnsmasq-base` and `libnftables1` archives. The runner attaches the root image read-only and keeps the guest interface setup in RAM. [Hwsim overview](https://docs.kernel.org/networking/mac80211_hwsim.html)

```sh
bash tests/wifi-chooser/run-vm.sh
```

## Secured networks

The fixture generates a temporary network name and two independent passphrases for each guest boot. It loads NetworkManager's real applet secret agent, taps the owned network row, and waits for the GTK password dialog. It drives the masked entry and **Connect** button through AT-SPI. The retry test submits a wrong passphrase and requires NetworkManager to attempt configuration and return to authentication or fail without activation. It then enters the correct passphrase in the renewed dialog. The fixture verifies the active profile's key management, association, an address from the DHCP range, and an interface-bound ping to the AP. Logs contain only status and counts. [Secret-agent and state checks](../tests/wifi-chooser/probe.py) · [Guest-only AP configuration](../tests/wifi-chooser/prepare-ap.py)

`WIFI_ACTOR=seat` opens a PAM session for the image's unprivileged `y700` account on the guest's foreground VT. It checks that logind identifies it as an active local X11 seat, and that NetworkManager grants network control through the image's shipped polkit policy. The applet and private Xvfb run from that session. This covers stock-policy authorization and GTK dialog behavior in QEMU. The Onboard experiment did not complete the password entry in the nested display. A finger-driven secure reconnect on the tablet remains untested. [Seat checks](../tests/wifi-chooser/seat-actor.sh)

On the exact Y700 kernel, NetworkManager 1.52.1-1 and applet 1.36.0-3 completed WPA2-Personal authentication, DHCP and the wireless ping from the ordinary seat after rejecting the first passphrase. The wrong WPA2 attempt returned to `NEED_AUTH` with `SUPPLICANT_DISCONNECT`. An SAE-only AP requiring management frame protection passed the same connection checks with the correct first passphrase. [NetworkManager wrong-PSK path](https://github.com/NetworkManager/NetworkManager/blob/1.52.1/src/core/devices/wifi/nm-device-wifi.c#L2335-L2408)

The wrong-passphrase SAE check under the fixture administrator ended in `FAILED` with `SSID_NOT_FOUND`. The applet still listed the AP for re-selection, but presented no second password dialog within 50 seconds of the second tap. NetworkManager's immediate wrong-PSK handler covers a four-way-handshake disconnect with `wpa-psk`. Its later timeout handler only asks for new secrets if its internal association path found the SSID. The observed reason fits that timeout branch. The underlying supplicant transition and physical behavior remain open. [Association timeout handling](https://github.com/NetworkManager/NetworkManager/blob/1.52.1/src/core/devices/wifi/nm-device-wifi.c#L2881-L2912)

```sh
WIFI_SECURITY=wpa2 WIFI_ACTOR=seat bash tests/wifi-chooser/run-vm.sh
WIFI_SECURITY=sae WIFI_ATTEMPT=fresh WIFI_ACTOR=seat bash tests/wifi-chooser/run-vm.sh
```
