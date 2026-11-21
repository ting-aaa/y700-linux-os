# Wi-Fi password re-entry

This ARM64 package adds two paths to Debian trixie's NetworkManager 1.52.1-1. Both use the existing masked nm-applet password dialog on the Y700 desktop.

| AP report during an SAE connection attempt | User-visible behavior |
| --- | --- |
| The supplicant emits `SaePasswordMismatch` | The active connection immediately requests a new password. This requires a supplicant which exports the signal. |
| A legacy AP reports unspecified authentication failure (status 1), and the manual attempt times out before associating | The next explicit selection of that same visible AP and saved profile within three minutes offers password re-entry. Debian's 2.10-24 supplicant exposes the required status property. |
| AP absent, unrelated IP failure, cancellation, automatic reconnect, or another manual selection | Ordinary NetworkManager behavior applies. |

The status-1 path reads live interface property changes. It ignores the initial snapshot, records one temporary selection per device and matches the caller's UID, the saved profile UUID and the scanned AP's exported object path. A second manual selection consumes the marker. A new scan object or an expired marker uses the usual activation path. Status 1 can have other causes, so the first rejection by itself never requests a password. The eligible second selection asks the user. The agent handles cancellation and secret storage. Both branches keep the profile's SAE settings.

The explicit-mismatch branch backports NetworkManager commit `bcb96a1b19da`. Trixie's supplicant already exposes the live `AuthStatusCode` property. Its matching hostapd can return status 1 for an invalid SAE confirmation. nm-applet passes the chosen AP's D-Bus path even for saved connections. [Upstream NetworkManager change](https://github.com/NetworkManager/NetworkManager/commit/bcb96a1b19dae7306be0b373f0cf76660499ac61) · [Debian supplicant events](https://sources.debian.org/src/wpa/2%3A2.10-24/wpa_supplicant/events.c/) · [Debian AP authentication](https://sources.debian.org/src/wpa/2%3A2.10-24/src/ap/ieee802_11.c/) · [Debian chooser](https://sources.debian.org/src/network-manager-applet/1.36.0-3/src/applet-device-wifi.c/)

## Building on Debian trixie ARM64

Enable the matching Debian source repository in a disposable build root, install the build dependencies for `network-manager`, and download the source and the stock binary. Run from the project checkout. The four exact archive hashes are in `sources.sha256`.

```sh
mkdir inputs output
(cd inputs && apt-get source --download-only network-manager=1.52.1-1 && apt-get download network-manager=1.52.1-1)
JOBS=4 bash packaging/wifi-sae-retry/build.sh inputs output
bash packaging/wifi-sae-retry/check-package.sh \
  inputs/network-manager_1.52.1-1_arm64.deb \
  output/network-manager_1.52.1-1+0y7001_arm64.deb
```

The builder applies Debian's source patch series, adds the SAE patch and uses Debian's own Meson configuration to compile the daemon and its internal Wi-Fi plugin together. The package retains the stock exact dependency on `libnm0 (= 1.52.1-1)`. Its two replacement ELFs, package metadata and Debian changelog can be checked against the original archive with `check-package.sh`. The version sorts above the stock release and below a `+deb13u1` update.

The stock ARM64 archive from `inputs` restores the previous daemon and plugin using `dpkg -i`. Replacing a running network service may interrupt the link used for installation. The exercised installation and rollback use an offline image overlay.
