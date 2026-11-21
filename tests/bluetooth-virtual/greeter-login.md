# Cold login with a bonded Bluetooth LE keyboard and mouse

Run this fixture on a Linux PC with the host tools and ARM64 inputs listed in [the Bluetooth test guide](../../docs/BLUETOOTH-VIRTUAL.md). Extract the raw `root.ext4` and the default `kernel.efi` from dev12.12. The runner verifies both and checks the running kernel notes inside each VM.

```bash
export Y700_BT_ROOT_FORMAT=raw Y700_BT_RELEASE_KERNEL="$dev1212_kernel"
export XORG_DUMMY_DEB="$arm64_dummy_video_deb"
bash tests/bluetooth-virtual/run-qemu.sh "$dev1212_root" "$kernel_build" \
    "$busybox_arm64" "$uv_arm64" "$bluez_582_source" "$btvirt_arm64" --cold-le-login
```

The first boot pairs two emulated controllers through BlueZ, verifies keyboard and mouse input, powers down the accessory and shuts down. The second VM boots the release kernel again. A private temporary disk carries the two bond stores and the fixture's generated password across power-off. The release root is mounted read-only in both VMs. Each boot sets the disposable account's password in its RAM overlay.

The second boot starts the installed Bluetooth system service and LightDM with the Arctica greeter on dummy Xorg. With both controllers non-pairable, the test requires automatic reconnection, the original reciprocal keys, an HCI long-term-key reply and encrypted traffic. It rejects a new SMP pairing exchange. The keyboard sends HID-over-GATT reports through the guest kernel and Xorg to the greeter. The observer verifies the username and focused password control. It checks the resulting ordinary user's Xfce session with logind, correlates the mouse reports with the Bluetooth event node and observes cursor movement on that desktop.

The fixture then locks the session through Xfce's autostarted screensaver. The bonded keyboard wakes the native dialog, submits a known incorrect password and receives a PAM rejection. Escape closes the dialog while the saver remains active. A second wake and the generated password unlock the original seat. The test requires the same logind session ID, account and Xfce process ID after unlock. A complete run prints `Y700_LE_SAME_SESSION_UNLOCK_PASS`, two successful guest exits and `Y700_COLD_BOND_PERSISTENCE_PASS`. The reduced receipt is generated from the two boots and excludes credentials, keys and raw HCI traffic.

The tests use virtual controllers and a dummy display. Bluetooth radio power, range and pairing behaviour with physical keyboards or mice require separate measurements on the tablet.
