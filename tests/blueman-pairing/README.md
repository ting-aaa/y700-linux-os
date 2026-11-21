# Keyboard-only LE pairing on the dev12.12 desktop

The `--blueman-keyboard` case runs two virtual LE controllers in an ARM64
QEMU guest. It verifies the SHA-256 of the released dev12.12 root and kernel,
the running kernel notes, and the installed Blueman package version. The guest
uses a read-only root with a RAM overlay and an empty bond store.

```sh
export Y700_BT_ROOT_FORMAT=raw
export Y700_BT_RELEASE_KERNEL=/path/to/dev12.12/kernel.efi
export XORG_DUMMY_DEB=/path/to/xserver-xorg-video-dummy_arm64.deb
bash tests/bluetooth-virtual/run-qemu.sh "$DEV1212_ROOT_EXT4" "$Y700_KERNEL_BUILD" \
    "$ARM64_BUSYBOX" "$ARM64_UV" "$BLUEZ_582_SRC" "$ARM64_BTVIRT" --blueman-keyboard
```

On the accessory controller the distribution's interactive `bluetoothctl`
registers a `KeyboardOnly` agent and initiates pairing. On the desktop the
ordinary user's Blueman applet displays the passkey on a 200% GTK/X11 display.
The observer locates the visible label for the exact accessory and types its
six digits and Return into the accessory's private terminal. A successful
match must create a bond at both ends and dismiss the displayed code.

The wire check verifies the negotiated I/O capabilities, 20 Secure
Connections passkey rounds, reciprocal DHKey checks, and an authenticated
P-256 key. On each of two desktop-initiated connections it checks all four
HID reports while the link is encrypted. On both connections evdev received
KEY_F15 and GTK received the matching X11 hardware keycode 193 (the stock
keymap calls it Launch6). Both layers also saw motion, left click and wheel.
Both connections share one pairing exchange.

The 2026-11-21 run passed on the released root and kernel. Eight HID reports
arrived in three ATT notifications across the two encrypted connections.
The virtual controller logged `Unable to disable LL privacy: -16` during
shutdown after the assertions passed. The guest and host runner both exited
with status 0. The receipt is `out/bluetooth-hid-radio/dev1212-keyboard-final.log`
(SHA-256 `2ab6eb05aaa212edaefa853eadbd4fd1b1c7daff6b395262a21200139a743fbd`).

The host retains reduced receipts. Terminal input, the bond store and the raw
protocol trace remain in guest RAM. This test covers virtual controllers on
the released kernel and a private Xorg display. The peer's BlueZ agent submits
the completed passkey. Separate GUI tests exercise intermediate digit-count
updates. [BlueZ Agent1 specification](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.Agent.rst)
· [bluetoothctl passkey input](https://github.com/bluez/bluez/blob/5.82/client/agent.c#L143-L165)

## Bluetooth Manager offline update

Build the two-package TAR from the qualified Blueman archives and run its
install, reinstall and rollback checks on an ARM64-capable Linux/WSL host.
The test mounts the sealed root read-only under an ephemeral overlay and
repeats the upgrade with the optional qcam y7007 package installed.

```sh
bash scripts/package-blueman-manager-update.sh "$BLUEMAN_DEBS" "$BUNDLE_TAR"
sudo bash tests/blueman-pairing/update-lifecycle.sh "$DEV1212_ROOT_EXT4" "$BUNDLE_TAR" "$QCAM7_DEB"
```

Extract the verified TAR into an empty directory. From `blueman-update`,
run `sha256sum -c SHA256SUMS`, then `sudo ./update-blueman-manager.sh install`.
Use `check` to validate the installed revision, `rollback` to return to y7002,
or `reinstall` to rerun dpkg for the current revision. An ordinary repeat
install verifies the existing bytes. The COW test also interrupts the normal
package sequence after unpacking in both directions, checks that verification
detects the pending configuration, and finishes the selected action. It checks
the package inventory, APT consistency and a locally modified conffile.

On a running system Debian's package script reloads systemd and requests a
restart of `blueman-mechanism.service`. Open the Manager again to load the
new interface. [Package versions and inventories](../../config/blueman-manager-update.lock.json)

## Search, select, pair and trust on the desktop

Set `BLUEMAN_MANAGER_ORIENTATION=landscape` and `BLUEMAN_MANAGER_LANGUAGE=en`
when invoking `tests/blueman-passkey-lifetime/run.sh` on the dev12.12 raw root.
Pass the X11 archive directory, python3-dbusmock archive, ARM64 uv and the
y7003 archive and SHA-256 in the order printed by that runner. Repeat with
`portrait` and `zh`. The test installs Blueman on a temporary copy-on-write
root, launches the package's desktop entry as an ordinary user and maximizes
the actual Xfce window. GTK scale is two. The system and session buses,
accessories, desktop and home all belong to the fixture.

Both runs opened and read the 2,379-character discovery failure, searched
again successfully, and selected, paired and trusted the mouse and keyboard
in sequence. Each peer received one Device1.Pair. In English landscape
(2560×1600) Search measured 208×96 physical pixels and Pair 174×96. In
Chinese portrait (1600×2560), both controls measured 178×96. The Xvfb
runs clicked the GTK controls with XTest. They check the installed manager's
D-Bus actions on modeled HID peers. The separate KeyboardOnly test above
uses real BlueZ pairing, encryption and HID over virtual HCI.

The English and Chinese Xvfb receipts are
`out/dev12.12-bt-desktop/manager-landscape-en-final.log` and
`out/dev12.12-bt-desktop/manager-portrait-zh-maximize2.log`.
[配对步骤](../../docs/BLUETOOTH-MANAGER.md)

## Physical controller discovery

The dev12.11 tablet now has the installed y7003 package and the offline y7002 rollback at `/var/lib/y700/updates/blueman-y7003`. Its package inventory changed from `a49b13a6…` to `a434ec3c…` with qcam y7007. The update kept the running Bluetooth, NetworkManager, SSH and LightDM service invocations.

```sh
bash tests/blueman-pairing/run-real-discovery.sh "$usb_ssh_wrapper" "$arm64_xvfb_deb" "$arm64_uv"
```

Start with the owner logged into Xfce, an idle powered adapter, and the Manager closed. The ordinary account starts the installed desktop entry's executable on a private 200% X display. The real session applet and the real system BlueZ bus handle the Search action. A complete physical run observed the WCN6855 entering discovery, returning to idle after 77.21 seconds, and enabling Search again. The test compares bonded, trusted and connected devices in memory, and emits only the comparison result. The receipt is `out/dev12.12-bt-desktop/installed-discovery-r2.log`. Physical HID input requires an accessory.

`run-manager-touch.sh` also boots the released ARM64 kernel and dev12.12
root in QEMU, installs y7003 in guest RAM, and runs the portrait test with
a Type-B kernel input device instead of XTest. See the usage line for the
eight inputs and `BLUEMAN_MANAGER_DEB`. The Xorg log must identify libinput
and the private evdev reader checks every contact's unique tracking ID and
release. Ten taps cover the error and its details, retry, device selection,
pairing and trust for both peers. The GTK app runs as uid 1000. The headless
guest gives that user read access to its empty rfkill device while it models
the two HID accessories on the private BlueZ bus.

The Chinese portrait run closed the Manager via its own Quit action before
removing the test buses. The guest and host exited successfully. Receipt
`out/dev12.12-bt-desktop/manager-typeb-final.log`, SHA-256
`8b4bf91a3141b17efaa7b832f39acc0af48080075fbb9659b8ed7031b3bf5f4a`.
