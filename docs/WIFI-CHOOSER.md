# Xfce Wi-Fi chooser on Y700

## Radio bands and reconnection on the physical tablet

The tablet's supplicant journal recorded a completed association on 5220 MHz. After 2,639.6 seconds the station reported disconnect reason 34. It scanned, associated on 2437 MHz with another BSSID advertising the same SSID and completed WPA negotiation 6.728 seconds after the disconnect. The supplicant network ID stayed the same. The same NetworkManager instance renewed both leases with their previous addresses. Its final IPv6 lease arrived 6.760 seconds after the disconnect and its IPv4 lease at 6.777 seconds, respectively 32 ms and 49 ms after authentication completed. The wireless device's last recorded state was activated, with no intervening device state change before either final lease. Application traffic across this physical transition was not captured. [Anonymized association and lease history](../tests/wifi-association-history.py)

In a November 20 read-only cache check, the physical tablet was associated at 2437 MHz using WPA2-PSK. NetworkManager knew two saved wireless profiles. Of 29 cached 2.4 GHz BSSes, one matched the active network name and profile. Its cache had zero 5 or 6 GHz entries at that instant. This observation used existing AP objects and requested no scan or network change. The helper prints aggregate counts and advertised authentication modes. [Cached candidate check](../tests/wifi-cached-candidates.py) · [NetworkManager security flags](https://networkmanager.dev/docs/api/latest/nm-dbus-types.html#NM80211ApSecurityFlags)

In a later passive scan on this tablet, `iw` returned 30 BSS entries on 2.4 GHz and 14 on 5 GHz. No 6 GHz entry appeared. NetworkManager advertises all three bands, and the active 2437 MHz WPA2 connection stayed up. The scan counts include separate BSSes advertising the same network name. [Privacy-preserving survey](../tests/wifi-band-survey.sh)

The separate WPA3 test used the real NetworkManager applet in an ordinary ARM64 guest desktop. Stopping its isolated access point dropped the association, IPv4 address and reachability. After the AP restarted, the station recovered twice on the same BSSID (12 and 10 seconds) and once on a different BSSID of the same network (13 seconds). Each cycle established a new activation of the original profile, negotiated SAE and protected management frames, obtained DHCP configuration and passed interface-bound pings. The applet needed no input after the first password. These times include verification on emulated hardware. [WPA3 outage fixture](../tests/wifi-rejoin/README.md)

## Signed wireless regulatory database

The [standalone dev12.5 archive](DEV12.5-IMAGE.md) includes the upstream-signed regulatory files in its initramfs and selects the matching Debian package alternative on the root filesystem. In a full ARM64 EFI boot of the delivered kernel and initramfs, cfg80211 applied the test guest's CN country hint without a database or signature error. The country hint was supplied by the virtual test entry. The distributed boot entry sets no such hint. [Archive and boot evidence](BOARD-IMAGE.md#dev125-standalone-image)

The physical `7.3.4-asphalt-prc` kernel requested `regulatory.db` at boot time 4.293 s, before it ran `/init` at 4.299 s. Its old initramfs lacked the file. The installed Debian root also selected a database signed with the Debian key, while this kernel trusts the upstream `sforshee` and `wens` keys. Debian's `wireless-regdb` package supplies both signatures and supports selecting the upstream pair for a custom kernel. The WCN6855's `ath11k` regulatory domain is managed by its firmware. Its separate `regdb.bin` and board calibration are distinct from cfg80211's signed database. [Debian maintainer's instructions](https://lists.debian.org/debian-release/2026/02/msg00250.html) · [Linux wireless regulatory database](https://wireless.docs.kernel.org/en/latest/en/developers/regulatory/wireless-regdb.html) · [ath11k self-managed domain](https://github.com/torvalds/linux/blob/v7.0/drivers/net/wireless/ath/ath11k/reg.c)

The board-image builder now places the authenticated upstream pair in the initramfs and selects the same pair inside the staged Debian root. The original and KMS kernels each passed three radio-free cold boots in ARM64 QEMU. Without the file they reported a missing database. With the Debian signature they rejected it. With the upstream signature they loaded the test rules. A separate 994-package image assembled with the production script passed FAT and ext4 readback and booted through EFI to systemd. Previously sealed images keep their original initramfs. [Early-boot test and hashes](../tests/wifi-regdb/README.md)

The running tablet retained its original boot files. Its root now selects the upstream pair, and the compatibility unit reloads it after the root mounts and before NetworkManager starts on legacy installations. Starting the unit on the running tablet returned success from the kernel. Across the reload, all 51 WLAN-bound gateway pings returned, the active connection profile stayed the same, and NetworkManager, the supplicant, SSH, LightDM and Bluetooth kept their service invocations. The before/after `iw reg get` rules for the self-managed PHY matched. The test made no country selection on the tablet.

In a separate ARM64 systemd boot with the legacy initramfs and a read-only dev12.4 root under an in-memory overlay, the early request failed as on the physical tablet. The compatibility unit completed successfully before NetworkManager became active. Removing the unit and the newly installed `iw` package and restoring automatic alternatives selection recovered the original configuration. [Legacy boot and rollback fixture](../tests/wifi-regdb-legacy/run.sh)

For a Y700 Debian installation that uses the old initramfs and this upstream-key kernel, install Debian's `iw` and `wireless-regdb` packages. Note the existing `update-alternatives --query regulatory.db` selection for rollback, then use the following from the product checkout. New images built with the corrected initramfs already carry the signed early-boot files. [Legacy systemd unit](../packaging/wifi-regdb/y700-wireless-regdb.service)

```sh
sudo apt-get install iw wireless-regdb
sudo update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
sudo install -m 644 packaging/wifi-regdb/y700-wireless-regdb.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now y700-wireless-regdb.service
systemctl show y700-wireless-regdb.service -p Result -p ExecMainStatus
iw reg get
```

To remove this compatibility setup, disable and stop the unit, remove its file from `/etc/systemd/system`, run `systemctl daemon-reload` and restore the previous alternatives mode and selection. On the tested tablet the previous setting was automatic. A rollback script and the original selection were retained locally.

## Physical LAN transfer

On November 20 the running TB320FC_PRC exchanged data directly with a Windows WLAN peer on its existing access point. The tablet used `ath11k_pci`. Its supplicant reported a completed WPA2-PSK association with CCMP, 2,437 MHz and 40 MHz channel width. The host bound its Wi-Fi IPv4 address, and the tablet bound the address selected by its on-link wireless route back to that peer. USB SSH started the test and returned measurements. [Linux wireless station information](https://wireless.docs.kernel.org/en/latest/en/users/documentation/iw.html)

| 32 MiB of TCP application data per transfer | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Received by tablet, Mbit/s | 78.59 | 81.86 | 79.60 | 79.60 |
| Sent by tablet, Mbit/s | 102.76 | 111.97 | 106.69 | 106.69 |

The receiving side verified SHA-256 on each of the six transfers (192 MiB total). The tablet wireless interface counted 104,756,294 received bytes and 106,026,576 transmitted bytes, including protocol overhead and other traffic. Its RX and TX error and drop counters each increased by zero. These figures cover this access point, band, peer and TCP workload. Physical WPA3, roaming and resume remain open.

The same tablet and Windows peer subsequently exchanged 288 MiB over IPv6 on the existing WLAN. Each run sent three payloads in each direction. The receiver checked every SHA-256. The dual-stack fixture also completed a shorter IPv4 run. At the start and after each bidirectional round the tablet reported 2437 MHz. The WLAN counters reported zero new errors or drops in all three completed runs.

| On-link address used | Payload per transfer | Total verified | Median tablet receive | Median tablet send |
| --- | ---: | ---: | ---: | ---: |
| Global IPv6 unicast | 32 MiB | 192 MiB | 64.30 Mbit/s | 79.76 Mbit/s |
| Link-local IPv6 | 16 MiB | 96 MiB | 65.25 Mbit/s | 83.57 Mbit/s |
| IPv4 | 8 MiB | 48 MiB | 56.48 Mbit/s | 83.39 Mbit/s |

The first link-local TCP connection timed out before any payload. A subsequent attempt completed all six transfers. The cause of that timeout is open. Each side used its own WLAN interface index for the scoped IPv6 address. The global-address test stayed on the local network. Internet IPv6 and continuity across a change of access point require separate tests. [Python socket address formats](https://docs.python.org/3/library/socket.html#socket-families)

In a separate 300.8-second observation, 301 of 301 gateway pings bound to the physical WLAN returned. Round-trip times were 5.914 ms minimum, 21.617 ms mean and 108.884 ms maximum. The tablet retained the same boot and active connection profile. Both endpoints of the observation showed WPA2-PSK with CCMP and a 40 MHz channel. The journal recorded no matching disconnection, firmware crash or driver timeout during this window.

To reproduce from a peer on the same LAN, set `HOST_WLAN_IP` to its local IPv4 or IPv6 address and `USB_SSH` to the host-key-verified tablet SSH wrapper. For link-local IPv6, append `%` and the peer's numeric WLAN interface index. The tablet starts a short-lived, unprivileged listener on its chosen WLAN address. Pass the wrapper command last. On Windows with the wrapper in WSL, replace `bash "$USB_SSH"` with `wsl -d Ubuntu -u root --exec bash "$USB_SSH"`. Successful output contains rates, available frequency samples and counter deltas and omits network identities. [Transfer fixture](../tests/wifi-lan-transfer.py)

```sh
uv run --no-project --python 3.13 python tests/wifi-lan-transfer.py \
    --host "$HOST_WLAN_IP" --mib 32 --control bash "$USB_SSH"
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
