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

The applet showed one available row. A synthesized tap on that row led to `NM_DEVICE_STATE_ACTIVATED` and a lease from the guest's DHCP range. Independent `iw` and `ip` checks confirmed association and the address. A ping reached the guest-owned AP. The fixture used the guest administrator account, a RAM-only overlay and no QEMU network interface. The test covers open-network association and local IPv4 connectivity. Password entry, connection from an ordinary logged-in seat and live radio reconnect require separate checks. [QEMU runner](../tests/wifi-chooser/run-vm.sh)

To repeat, set `KERNEL_IMAGE`, `RAW_ROOT`, `HWSIM_MODULE`, `QEMU`, `QEMU_DATA`, `ARM64_BUSYBOX` and `ARM64_UV` to the prepared artifacts. Set `X11_DEBS` to the ARM64 archive directory used above and `WIFI_DEBS` to matching Debian 13 ARM64 `hostapd`, `iw`, `dnsmasq-base` and `libnftables1` archives. The runner attaches the root image read-only and keeps the guest interface setup in RAM. [Hwsim overview](https://docs.kernel.org/networking/mac80211_hwsim.html)

```sh
bash tests/wifi-chooser/run-vm.sh
```
