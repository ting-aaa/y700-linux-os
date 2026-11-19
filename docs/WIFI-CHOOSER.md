# Xfce Wi-Fi chooser on Y700

## Physical LAN transfer

On November 20 the running TB320FC_PRC exchanged data directly with a Windows WLAN peer on its existing access point. The tablet used `ath11k_pci`. Its supplicant reported a completed WPA2-PSK association with CCMP, 2,437 MHz and 40 MHz channel width. The host bound its Wi-Fi IPv4 address, and the tablet bound the address selected by its on-link wireless route back to that peer. USB SSH started the test and returned measurements. [Linux wireless station information](https://wireless.docs.kernel.org/en/latest/en/users/documentation/iw.html)

| 32 MiB of TCP application data per transfer | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Received by tablet, Mbit/s | 78.59 | 81.86 | 79.60 | 79.60 |
| Sent by tablet, Mbit/s | 102.76 | 111.97 | 106.69 | 106.69 |

The receiving side verified SHA-256 on each of the six transfers (192 MiB total). The tablet wireless interface counted 104,756,294 received bytes and 106,026,576 transmitted bytes, including protocol overhead and other traffic. Its RX and TX error and drop counters each increased by zero. These figures cover this access point, band, peer and TCP workload. Physical WPA3, roaming and resume remain open.

In a separate 300.8-second observation, 301 of 301 gateway pings bound to the physical WLAN returned. Round-trip times were 5.914 ms minimum, 21.617 ms mean and 108.884 ms maximum. The tablet retained the same boot and active connection profile. Both endpoints of the observation showed WPA2-PSK with CCMP and a 40 MHz channel. The journal recorded no matching disconnection, firmware crash or driver timeout during this window.

To reproduce from a peer on the same LAN, set `HOST_LAN_IPV4` to its local IPv4 address and `USB_SSH` to the host-key-verified tablet SSH wrapper. The tablet starts a short-lived, unprivileged listener on its chosen WLAN address. Pass the wrapper command last. On Windows with the wrapper in WSL, replace `bash "$USB_SSH"` with `wsl -d Ubuntu -u root --exec bash "$USB_SSH"`. Successful output contains rates and counter deltas and omits network identities. [Transfer fixture](../tests/wifi-lan-transfer.py)

```sh
uv run --no-project --python 3.13 python tests/wifi-lan-transfer.py \
    --host "$HOST_LAN_IPV4" --mib 32 --control bash "$USB_SSH"
```

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

To repeat, set `KERNEL_IMAGE`, `RAW_ROOT`, `HWSIM_MODULE`, `QEMU`, `QEMU_DATA`, `ARM64_BUSYBOX` and `ARM64_UV` to the prepared artifacts. For a QCOW2 root, pass its path as `RAW_ROOT` and set `ROOT_FORMAT=qcow2`. Set `X11_DEBS` to the ARM64 archive directory used above and `WIFI_DEBS` to matching Debian 13 ARM64 `hostapd`, `iw`, `dnsmasq-base` and `libnftables1` archives. The runner attaches the root image read-only and keeps the guest interface setup in RAM. [Hwsim overview](https://docs.kernel.org/networking/mac80211_hwsim.html)

```sh
bash tests/wifi-chooser/run-vm.sh
```

## Secured networks

The fixture generates a temporary network name and two independent passphrases for each guest boot. It loads NetworkManager's real applet secret agent, taps the owned network row, and waits for the GTK password dialog. It drives the masked entry and **Connect** button through AT-SPI. The retry test submits a wrong passphrase and requires NetworkManager to attempt configuration and return to authentication or fail without activation. It then enters the correct passphrase in the renewed dialog. The fixture verifies the active profile's key management, association, an address from the DHCP range, and an interface-bound ping to the AP. Logs contain only status and counts. [Secret-agent and state checks](../tests/wifi-chooser/probe.py) · [Guest-only AP configuration](../tests/wifi-chooser/prepare-ap.py)

`WIFI_ACTOR=seat` opens a PAM session for the image's unprivileged `y700` account on the guest's foreground VT. It checks that logind identifies it as an active local X11 seat, and that NetworkManager grants network control through the image's shipped polkit policy. The applet and private Xvfb run from that session. The 200% Onboard password recovery is described below. A finger-driven secure reconnect on the tablet remains untested. [Seat checks](../tests/wifi-chooser/seat-actor.sh)

On the exact Y700 kernel, NetworkManager 1.52.1-1 and applet 1.36.0-3 completed WPA2-Personal authentication, DHCP and the wireless ping from the ordinary seat after rejecting the first passphrase. The wrong WPA2 attempt returned to `NEED_AUTH` with `SUPPLICANT_DISCONNECT`. An SAE-only AP requiring management frame protection passed the same connection checks with the correct first passphrase. [NetworkManager wrong-PSK path](https://github.com/NetworkManager/NetworkManager/blob/1.52.1/src/core/devices/wifi/nm-device-wifi.c#L2335-L2408)

The wrong-passphrase SAE check under the fixture administrator ended in `FAILED` with `SSID_NOT_FOUND`. The applet still listed the AP for re-selection, but presented no second password dialog within 50 seconds of the second tap. NetworkManager's immediate wrong-PSK handler covers a four-way-handshake disconnect with `wpa-psk`. Its later timeout handler only asks for new secrets if its internal association path found the SSID. The observed reason fits that timeout branch. The underlying supplicant transition and physical behavior remain open. [Association timeout handling](https://github.com/NetworkManager/NetworkManager/blob/1.52.1/src/core/devices/wifi/nm-device-wifi.c#L2881-L2912)

```sh
WIFI_SECURITY=wpa2 WIFI_ACTOR=seat bash tests/wifi-chooser/run-vm.sh
WIFI_SECURITY=sae WIFI_ATTEMPT=fresh WIFI_ACTOR=seat bash tests/wifi-chooser/run-vm.sh
```

## Correct a saved WPA3 password

On the tablet desktop, open **Applications → Settings → Advanced Network Configuration**. In **Network Connections**, select the saved Wi-Fi network and tap **Edit** (the pencil). Open **Wi-Fi Security**, replace the password and tap **Save**. Watch the network icon for reconnection. If it stays disconnected, tap the icon and select the saved network from the menu or **Available networks**.

On 2026-11-20 the ordinary `y700` seat on the corrected ARM64 dev9 image reproduced the SAE failure. After the first, incorrect password, NetworkManager attempted configuration and entered `FAILED` with `SSID_NOT_FOUND`. Tapping the advertised network again produced no password dialog during a 50-second observation. The separate editor run opened the stock Xfce Applications menu and followed the path above. The original profile UUID then activated. The AP independently reported negotiated SAE (AKM selector `00-0f-ac-8`) and protected management frames. The station received a DHCP lease and an interface-bound ping reached the AP in its separate network namespace. [Connection-editor source](https://github.com/GNOME/network-manager-applet/tree/1.36.0/src/connection-editor)

The 2560 × 1600 guest used the installed Xfce 200% scale profile and Onboard's stock landscape dock. Pointer taps opened the chooser and editor. Onboard appeared at each focused password field and entered two independently generated 16-letter passwords through its visible keys. In the editor the test used Onboard's Ctrl+A and Backspace when the field contained the prior password. AT-SPI checked the masked length after each letter. The station automatically activated the edited profile while the applet menu reopened. The test verified its UUID and the other saved profile's non-secret settings. This exercises the screen-keyboard path in the native ARM64 guest. The panel digitizer and a physical WPA3 access point remain separate measurements.

The fixture used the dev9 QCOW2 with SHA-256 `18c58b29bad672bc0a3971f4e68b49c3c27101a9759f87da8acde640ef4b02e2`, kernel `7.3.4-asphalt-prc` and the test-only hwsim module with SHA-256 `4af31aa7043ef4f21f703ba9f8f76dfe92b4450ecc3b6731c0997345ebca23b2`. The access point, network name and credentials were ephemeral. [GUI path](../tests/wifi-chooser/probe.py) · [Negotiated SAE and ping checks](../tests/wifi-chooser/fixture-guest.sh)

| Local receipt under `out/wifi-sae-dev9/` | Result | SHA-256 |
| --- | --- | --- |
| `reselect-final.log` | Selecting the advertised network after the failed password produced no second prompt in 50 seconds | `0aa33be18a9a56a859eb8d1b05c06d0ae075aab2a9538c547234e7af781be0a5` |
| `editor.log` | GTK accessible entry and GUI editor recovery, negotiated SAE/PMF and ping | `0de2abc6622eb552b6cd61f6928d35c9bde80fcee07ec8a2c71f9e51f41522f6` |
| `onboard.log` | 200% Onboard entry for both passwords, GUI editor recovery, negotiated SAE/PMF and ping | `7a5a7ad581ae0ba358f8ccc034f694dccd8c7c3c303e0469bc25e67fdf630d30` |

```sh
ROOT_FORMAT=qcow2 WIFI_SECURITY=sae WIFI_ATTEMPT=editor WIFI_ACTOR=seat bash tests/wifi-chooser/run-vm.sh
ROOT_FORMAT=qcow2 WIFI_SECURITY=sae WIFI_ATTEMPT=onboard WIFI_ACTOR=seat bash tests/wifi-chooser/run-vm.sh
```
