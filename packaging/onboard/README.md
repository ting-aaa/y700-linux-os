# Onboard hardware-keyboard preference

The board build repacks the authenticated Debian ARM64 `onboard` archive and
patches three Python modules. Debian's native `Onboard.osk` extension and the
stock `onboard-common` and `onboard-data` packages remain compatible. The
setting controls whether an attached typing keyboard suppresses automatic
display of the on-screen keyboard.

The stock preference callback changes the tablet-mode listener. The patch
updates the udev listener and immediately rechecks the current keyboard and
editable focus when the preference changes. The normal hotplug handler
applies the visibility decision. Debian's native enumerator still classifies
keyboards. The GLib observer from the locked `python3-pyudev` package receives
input hotplug events on the main loop. The tracker removes that observer and
the exception-list callback together on disable. The original native event
watch calls Python from a GLib callback without acquiring the interpreter
lock. [Debian
preference callback](https://sources.debian.org/src/onboard/1.4.1-10/Onboard/Keyboard.py/#L2359)
· [Visibility handler](https://sources.debian.org/src/onboard/1.4.1-10/Onboard/AutoShow.py/#L315)
· [Native event callback](https://sources.debian.org/src/onboard/1.4.1-10/Onboard/osk/osk_udev.c/#L177)

## Inputs and offline build

The original ARM64 archive is pinned in `config/debian-base.lock.json`.
The three original Python files also match Debian's patched source tree byte
for byte. The trixie `InRelease` signature, its `main/source/Sources.xz`
digest and the `onboard` source stanza were checked against the Debian
archive keyring. [Debian source package](https://sources.debian.org/src/onboard/1.4.1-10/)

| Input | SHA-256 |
| --- | --- |
| Archive `onboard_1.4.1-10_arm64.deb` | `743bd899a89e8ad1bc6e8f9d199e754de1299c53b288775db1184165e12a2329` |
| Source `onboard_1.4.1-10.dsc` | `1991a0b71ea22c2244f4d8d89e88d2ffb6d98f7be7a1b42d446c8f21789f6cc1` |
| `onboard_1.4.1.orig.tar.gz` | `01cae1ac5b1ef1ab985bd2d2d79ded6fc99ee04b1535cc1bb191e43a231a3865` |
| `onboard_1.4.1-10.debian.tar.xz` | `3a8db945e1780c0f76e0bc04219bea01130b9ff0a2437d15bf887aebd960c747` |

Run on a Linux build host with Bash, uv, Python 3, GNU patch and dpkg-deb.
The version and SHA-256 of the result are recorded in `config/onboard.lock.json`.

```sh
mkdir -p out/onboard-offline
bash scripts/build-onboard-detection.sh \
    out/onboard-rollback/onboard_1.4.1-10_arm64.deb out/onboard-offline
```

## Upgrade and rollback

On an existing board with the locked Debian Onboard installation, install the
single board archive. Start a fresh Onboard process once after package
replacement so that the running interpreter loads the updated modules.
Subsequent preference changes take effect in that process.

```sh
sudo dpkg -i out/onboard-offline/onboard_1.4.1-10+y7002_arm64.deb
```

To restore Debian's version, install the saved archive and start a new Onboard
process. Both directions retain the user's GSettings preferences.

```sh
sudo dpkg -i out/onboard-rollback/onboard_1.4.1-10_arm64.deb
```

Two independent offline builds produced identical archives. In a disposable
ARM64 root the upgrade, downgrade and reinstall each passed `dpkg -V onboard`
and `dpkg --audit`. The following check uses the installed native enumerator
and GLib observer in an isolated X display, cycles the listener 30 times, and tests the unavailable
monitor case.

```sh
uv run --offline --no-project --python /usr/bin/python3 python packaging/onboard/check-listener.py
```
