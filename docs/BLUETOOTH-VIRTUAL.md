# Bluetooth keyboard and mouse on the Y700 Debian kernel

On 2026-11-19, native ARM64 BlueZ 5.82 paired a simulated keyboard and mouse through both HID over GATT and Classic HIDP. The Y700 Debian dev9 kernel delivered keyboard, mouse button, pointer and wheel events after pairing and after reconnection. Each transport ran in a fresh QEMU guest with two virtual controllers, a read-only dev9 root and an empty temporary Bluetooth bond store.

| Transport | Pairing and HID evidence | Reconnection evidence |
| --- | --- | --- |
| LE HID over GATT | The central ran LE discovery, matched the peer address and service `0x1812`, called `Device1.Pair` and observed both `Paired` and `Bonded`. BlueZ resolved the GATT service and subscribed to the keyboard and mouse Report characteristics. | First, the central explicitly disconnected and connected again. Then the test marked the synthetic bond trusted and powered the peripheral controller off and on. When the accessory resumed connectable advertising, the central automatically reconnected and subscribed again. All three input checks passed. |
| Classic HIDP | Two BR/EDR-only controllers performed discovery and `Device1.Pair`. The central resolved the peer's HID service `0x1124` from SDP. The paired accessory opened the HID control and interrupt channels to the central on L2CAP PSMs `0x11` and `0x13`. | The first channels closed, the central confirmed `Connected=false` with its bond intact, and the accessory opened a second pair of channels. Both input checks passed. |

All five input checks opened Linux evdev nodes with bus type `BUS_BLUETOOTH` and the expected remote address in sysfs `uniq`. Each observed F15 press and release, left mouse button press and release, relative motion `X=+7` and `Y=-3`, vertical wheel `+1` and high-resolution wheel `+120`. Each guest used a pairing agent scoped to its two virtual peers and the Just Works association model. The separate radio test documents the physical WCN6855 and the Windows numeric-comparison boundary. Physical accessory pairing, desktop input, suspend/resume and bond persistence across a tablet reboot still require device measurements. [Physical radio evidence](BLUETOOTH-HID-RADIO.md)

## Reproduce

Use Linux with QEMU for AArch64, LLVM 21, `make`, `cpio` and `gzip`. The runner needs the project dev9 QCOW2 with its backing chain, the configured and built Y700 Linux 7.3.4 tree, static ARM64 BusyBox, ARM64 uv, the BlueZ 5.82 source tree and the ARM64 `btvirt` executable. Debian supplies the last executable in `bluez-test-tools`. The package used here was `5.82-1.1` with SHA-256 `e4ad401561bd0daf0bf13ca4761a8d9dc2a3261233da0e4b19f075ed3d1f694a`. Extract it with `dpkg-deb -x` and pass its `usr/bin/btvirt`. [Debian archive](https://snapshot.debian.org/binary/bluez-test-tools/5.82-1.1/)

```bash
inputs=("$root_qcow2" "$kernel_build" "$busybox_arm64" "$uv_arm64" "$bluez_src" "$btvirt_arm64")
bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}"
bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --classic
```

The runner accepts `QEMU_SYSTEM_AARCH64` and `QEMU_FIRMWARE_DIR` for a non-system QEMU installation. It verifies the Y700 kernel, module symbols, VHCI source, BlueZ example sources and `btvirt` hashes. The product kernel omits the virtual HCI driver. The runner builds that upstream driver as an external test module against the exact kernel tree and loads it in the VM. The product root supplies the regular Bluetooth, crypto and input modules, daemon, system D-Bus and Python libraries. The guest runs Python through uv and powers off after each test.

The tested root QCOW2 SHA-256 was `e7e389d621efa0ccc7969c8e53bbef1f2a490cb5d7e3ab7ad82365449a042f67`. The unchanged Image SHA-256 was `4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1`. With LLVM 21 the fixture VHCI module had SHA-256 `ce4384a353d31d7f5380f4c119827bb0633d77c29eaa097f841c355bf069e071`. A successful run prints `Y700_VIRTUAL_HOG_PASS` or `Y700_VIRTUAL_CLASSIC_INPUT_PASS`, followed by `Y700_VIRTUAL_HID_EXIT=0`. [Runner](../tests/bluetooth-virtual/run-qemu.sh)

The LE accessory publishes a HID report map and sends input through real GATT notifications. In the Classic guest, BlueZ's input plugin already owns both incoming HIDP ports on each adapter. The fixture uses the device-initiated connection mode and publishes a peer-specific SDP record using the guest daemon's local compatibility socket. The central input plugin stays enabled. [BlueZ HoG profile](https://github.com/bluez/bluez/blob/5.82/profiles/input/hog.c) · [Classic input server](https://github.com/bluez/bluez/blob/5.82/profiles/input/server.c) · [BlueZ virtual controller](https://github.com/bluez/bluez/blob/5.82/emulator/main.c)
