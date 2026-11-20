# Bluetooth keyboard and mouse on the Y700 Debian kernel

On 2026-11-19, native ARM64 BlueZ 5.82 paired a simulated keyboard and mouse through both HID over GATT and Classic HIDP. The Y700 Debian dev9 kernel delivered keyboard, mouse button, pointer and wheel events after pairing and after reconnection. Each transport ran in a fresh QEMU guest with two virtual controllers, a read-only dev9 root and an empty temporary Bluetooth bond store.

| Transport | Pairing and HID evidence | Reconnection evidence |
| --- | --- | --- |
| LE HID over GATT | The central ran LE discovery, matched the peer address and service `0x1812`, called `Device1.Pair` and observed both `Paired` and `Bonded`. BlueZ resolved the GATT service and subscribed to the keyboard and mouse Report characteristics. | First, the central explicitly disconnected and connected again. Then the test marked the synthetic bond trusted and powered the peripheral controller off and on. When the accessory resumed connectable advertising, the central automatically reconnected and subscribed again. All three input checks passed. |
| Classic HIDP | Two BR/EDR-only controllers performed discovery and `Device1.Pair`. The central resolved the peer's HID service `0x1124` from SDP. The paired accessory opened the HID control and interrupt channels to the central on L2CAP PSMs `0x11` and `0x13`. | The first channels closed, the central confirmed `Connected=false` with its bond intact, and the accessory opened a second pair of channels. Both input checks passed. |

All five input checks opened Linux evdev nodes with bus type `BUS_BLUETOOTH` and the expected remote address in sysfs `uniq`. Each observed F15 press and release, left mouse button press and release, relative motion `X=+7` and `Y=-3`, vertical wheel `+1` and high-resolution wheel `+120`. Each guest used a pairing agent scoped to its two virtual peers and the Just Works association model. The separate radio test documents the physical WCN6855 and the Windows numeric-comparison boundary. Physical accessory pairing, desktop input, suspend/resume and bond persistence across a tablet reboot still require device measurements. [Physical radio evidence](BLUETOOTH-HID-RADIO.md)

## Application input on the final dev9 image

The corrected dev9 QCOW2, SHA-256 `18c58b29bad672bc0a3971f4e68b49c3c27101a9759f87da8acde640ef4b02e2`, passed both evdev regressions. A second pair of runs sent the same Bluetooth reports to an ordinary GTK 3 window on Xorg. The window ran as `y700` (UID 1000), had keyboard focus, and received the input during all three LE connections and both Classic connections.

For each connection, the GTK observer resolved the event's GDK source device to a unique XInput slave, checked Xorg's libinput driver selection, and matched its `Device Node` to the paired Bluetooth peer's sysfs address and bus type. It recorded the X server timestamp and source ID for each event. The keyboard delivered press and release with X11 hardware keycode 193. The stock keymap reported `Launch6` for the HID F15 key. The mouse delivered left-button press and release, rightward and upward pointer motion, and upward scrolling. The kernel reported the unaccelerated motion and both wheel resolutions simultaneously.

The guest used the Xorg dummy video driver with automatic libinput discovery and a fresh authorized local display. The GTK window received input from the native BlueZ host stack. Real tablet pairing, Xfce keyboard shortcuts and suspend/resume remain separate physical tests. [GTK observer](../tests/bluetooth-virtual/desktop.py)

### Onboard detection of a function key and mouse

In both desktop runs, Xorg exposed the F15 report as a keyboard and the pointer report as a mouse. Each connected peer had two Bluetooth input nodes with a physical path. Debian udev set `ID_INPUT_KEYBOARD` on neither. The installed Onboard 1.4.1-10 enumerator returned zero text keyboards before pairing, during each connection and after each tested disconnect. Both nodes disappeared on disconnect, including when the virtual LE accessory powered off. The existing GTK observer still received the key and mouse events.

The reduced receipts are `out/bluetooth-virtual/onboard/le.log` and `classic.log` in the same directory. The original report map supplies F15 and pointer input for both transports.

Onboard's native filter requires `ID_INPUT_KEYBOARD=1` and a `PHYS` property. Debian's udev input classifier checks the low key bitmap for all keycodes 1 through 31. This excludes the fixture's F15-only interface and the tablet's single power and volume keys. [Onboard udev enumeration](https://sources.debian.org/src/onboard/1.4.1-10/Onboard/osk/osk_udev.c/#L99) · [systemd 257.13 input classifier](https://github.com/systemd/systemd/blob/v257.13/src/udev/udev-builtin-input_id.c#L367-L375)

## Typing and editing on dev12.5

On November 20 the sealed dev12.5 ARM64 root, SHA-256 `041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6`, passed five GTK text-entry checks with the Y700 7.3.4 kernel, BlueZ 5.82 and Onboard `1.4.1-10+y7002`. Two virtual controllers performed pairing inside each QEMU guest. The LE accessory used GATT notifications. The Classic accessory used the HIDP interrupt channel. Both advertised an eight-byte keyboard input report with modifier bits and six key slots alongside their mouse report. [Virtual accessory](../tests/bluetooth-virtual/keyboard.py)

| Transport | Connections that delivered text and pointer input |
| --- | --- |
| LE HID over GATT | Initial pairing, explicit reconnect, automatic reconnect after the bonded accessory powered off and resumed advertising |
| Classic HIDP | Initial bonded connection and accessory-initiated reconnect |

Each connection received a fresh eight-hex-digit challenge. The accessory typed `Hid `, the challenge and a deliberately extra letter. It sent Backspace, typed `X!` with Shift, moved left twice, inserted a hyphen and sent Ctrl+End. The focused GTK entry running as UID 1000 independently recorded the intermediate edits, final string and final cursor position. All five challenges matched. Every press and release came from the Xorg/libinput keyboard slave whose evdev node matched the paired address and `BUS_BLUETOOTH`. The kernel and GTK also observed the original F15, mouse button, motion and wheel sequence. [GTK input observer](../tests/bluetooth-virtual/desktop.py)

Onboard's installed native enumerator reported one typing keyboard while each full keyboard was connected and zero before pairing and after the observed disconnects. The F15-only profile remained available as a separate negative control. These PC runs exercise Xorg and GTK over the native BlueZ transports. Physical radio range, accessory compatibility, suspend and real tablet typing still need hardware measurements.

## LE bond across two cold boots

On 2026-11-20 the final dev9 image automatically reconnected to a bonded LE keyboard and mouse after a full guest shutdown. A new QEMU process booted the same read-only root and kernel. The two virtual controllers kept their addresses. Each boot ran a fresh stock `bluetoothd` managing both controllers. A private 16 MiB ext4 disk held both reciprocal BlueZ adapter stores across boots.

| Observation | First boot | Second boot |
| --- | --- | --- |
| Pairing and encryption | One `Device1.Pair` call. The HCI monitor recorded SMP pairing and AES-CCM. Both adapters stored long-term keys. | Both devices already reported `Paired` and `Bonded`, and the central still trusted the accessory. Both adapters had pairability disabled and the fixture registered zero agents. The monitor recorded a long-term-key reply, AES-CCM and zero SMP pairing requests or responses. Both sets of stored keys matched the first boot. |
| HID input | Both report subscriptions and the Bluetooth evdev nodes were present. | After the accessory advertised, the central connected, resolved HID and resubscribed without a `Connect` call. The matched Bluetooth input nodes delivered F15 press/release, left click/release, X +7, Y −3 and vertical wheel +1/+120. |

The test powers off the virtual accessory radio with its GATT service registered, waits for the central to observe link loss and checks that the HID UUID remains in both the central's on-disk `General/Services` and D-Bus UUID list. One exploratory power-off reported HCI opcode `0x0408` status `-107`. The repeat run recorded a clean link loss and encrypted reconnect.

An independent variant stops the peripheral application while the two radios are still linked. With that shutdown order, boot 2 loaded both bonds but the central's cached UUID list no longer contained HID. A BlueZ-only observation lasted 40 seconds without a passive reconnect. The management trace in a second run showed no auto-connect Add Device action `0x02` for the peer. An explicit `Device1.Connect` then restored encryption and both input devices without pairing again. Blueman's generic **Connect** action uses this D-Bus operation. Both variants run without the desktop applet. [BlueZ 5.82 profile matching](https://github.com/bluez/bluez/blob/5.82/src/device.c#L5160) · [Blueman Connect implementation](https://github.com/blueman-project/blueman/blob/2.4.4/blueman/plugins/applet/DBusService.py)

| Console receipt under `out/bluetooth-virtual/` | Connection on boot 2 | SHA-256 |
| --- | --- | --- |
| `cold-reboot-accessory-off.log` | Automatic | `38200d26e0eae2b426b63598211d11bf3160cc601609f2bc5e8376069d2ae17a` |
| `cold-reboot-linked.log` | Explicit after linked shutdown | `a553a13608c190d933ca9b23028150a9bda41ae8d60af093d635c03b88c4d271` |

The automatic-reconnect run used boot IDs `1792430d-1b51-48c4-922d-12160f0937fc` and `c9e81eca-9b79-4581-bd0e-e9b8e16731b6`. Raw HCI captures stayed inside each guest and the runner discarded the private bond disk. Cold-boot behavior of the tablet's WCN6855 and a physical accessory still requires a device measurement. [Cold-boot checks](../tests/bluetooth-virtual/cold-boot.py)

## Classic bond across two cold boots on dev12.7

The sealed dev12.7 root (`dd885eb7bc88e3fb87b0567ff7f382afbe079363910d6f0fd5b4bb41935e220a`) paired a virtual BR/EDR keyboard and mouse and reused the bond after the first VM powered off. A new QEMU process started with the same two controller addresses, a fresh BlueZ 5.82 daemon and the private ext4 adapter stores. The accessory initiated both HIDP channels on reconnect.

- On boot 1, one `Device1.Pair` produced matching nonzero Classic link keys in both device records. Both controllers reported successful Simple Pairing, a new-key notification and encryption on their connections.
- On boot 2, both controllers were non-pairable, the fixture registered no pairing agent, and both devices came back paired and bonded. Each controller requested its peer's link key. Linux returned the same 16 bytes saved on boot 1 for each remote address. Both controllers reported encryption for their respective ACL handles. The HCI trace contained zero new-key notifications or Simple Pairing completions for the pair.
- On both boots the ordinary user's focused GTK entry received the challenge, Shift, Backspace, cursor edits and Ctrl+End from the matched Bluetooth keyboard. The same paired device supplied relative mouse motion, a left click and upward scrolling. Onboard enumerated one typing keyboard on each connection. The private key store was discarded at the end of the run.

The runner checks the original BlueZ monitor packets, matching controller, each remote address and the encrypted ACL handle. It emits booleans for the key comparison. The reduced receipt is `out/bluetooth-virtual/cold-classic-run3.log`, SHA-256 `8aed3ad12fc7f7b986d78cd460ae6254cc614fbd8a5397ed43072bf3402ab94b`. [Cold-boot checks](../tests/bluetooth-virtual/cold-boot.py) · [BlueZ monitor packet format](https://github.com/bluez/bluez/blob/5.82/src/shared/btsnoop.h) · [BlueZ controller emulator](https://github.com/bluez/bluez/blob/5.82/emulator/btdev.c)

A second run paired the accessory on boot 1 and waited for the installed Arctica login screen on boot 2. LightDM and logind reported an active X11 greeter on seat0. Before the accessory connected, an observer running as the `lightdm` user found Arctica's focused, empty username field. After reconnect, Xorg/libinput exposed the keyboard and pointer from the bonded Bluetooth address. Using its HIDP keyboard reports, the accessory typed and edited a fresh challenge in the username field. The observer read back the exact result through AT-SPI. The matched evdev nodes also delivered F15, a left click, relative motion and wheel events while the greeter was active. The test ended before username submission or password entry. Pointer dispatch inside Arctica and physical tablet login remain unmeasured. [Greeter observer](../tests/bluetooth-virtual/greeter.py) · [Seat setup](../tests/bluetooth-virtual/greeter-seat.sh)

Both controllers again resumed encryption with their boot-1 link keys. This run used boot IDs `9d0d8bf1-5741-4f4a-838b-08050bcce076` and `f5388119-8d28-462c-aed2-be7c091ff953`. The reduced receipt is `out/bluetooth-virtual/cold-classic-greeter6.log`, SHA-256 `82715d23c9d39b096346a1ead4019e82ee49a3f7b2c9a20dd7b23e2d0fec3d41`.

## Reproduce

Use Linux with QEMU for AArch64, LLVM 21, `make`, `cpio` and `gzip`. The runner needs the project dev9 QCOW2 with its backing chain, the configured and built Y700 Linux 7.3.4 tree, static ARM64 BusyBox, ARM64 uv, the BlueZ 5.82 source tree and the ARM64 `btvirt` executable. Debian supplies the last executable in `bluez-test-tools`. The package used here was `5.82-1.1` with SHA-256 `e4ad401561bd0daf0bf13ca4761a8d9dc2a3261233da0e4b19f075ed3d1f694a`. Extract it with `dpkg-deb -x` and pass its `usr/bin/btvirt`. [Debian archive](https://snapshot.debian.org/binary/bluez-test-tools/5.82-1.1/)

```bash
inputs=("$root_qcow2" "$kernel_build" "$busybox_arm64" "$uv_arm64" "$bluez_src" "$btvirt_arm64")
bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}"
bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --classic
bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --cold-reboot
bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --cold-reboot-linked
```

For both GTK variants, repeat those commands with `XORG_DUMMY_DEB` set to Debian's ARM64 `xserver-xorg-video-dummy` package, version `1:0.4.0-1+b2`, SHA-256 `5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d`. Each window prints its source IDs, event nodes and observed events. The runner requires `Y700_GTK_HID_INPUT_PASS` once per connection.

For the dev12.5 typing checks, use the same kernel, emulator, BusyBox, uv, BlueZ and dummy-video inputs. Pass the extracted ext4 file as the first argument and select the raw format. Leave `Y700_BT_TYPING` unset to run the F15-only control. Both profiles open the product root read-only.

```sh
export XORG_DUMMY_DEB="$dummy_deb" Y700_BT_ROOT_FORMAT=raw
inputs=("$root_ext4" "$kernel_build" "$busybox_arm64" "$uv_arm64" "$bluez_src" "$btvirt_arm64")
Y700_BT_TYPING=1 bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}"
Y700_BT_TYPING=1 bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --classic
```

Point the first array entry at the exact dev12.7 ext4 root to reproduce the two-boot Classic test. The kernel, BlueZ sources, tools and dummy Xorg package are the same pinned inputs.

```sh
Y700_BT_TYPING=1 bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --cold-classic
Y700_BT_TYPING=1 Y700_BT_GREETER=1 bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --cold-classic
```

The runner accepts `QEMU_SYSTEM_AARCH64` and `QEMU_FIRMWARE_DIR` for a non-system QEMU installation. It verifies the Y700 kernel, module symbols, VHCI source, BlueZ example sources and `btvirt` hashes. The product kernel omits the virtual HCI driver. The runner builds that upstream driver as an external test module against the exact kernel tree and loads it in the VM. The product root supplies the regular Bluetooth, crypto and input modules, daemon, system D-Bus and Python libraries. The guest runs Python through uv and powers off after each test.

The initial evdev runs used root QCOW2 SHA-256 `e7e389d621efa0ccc7969c8e53bbef1f2a490cb5d7e3ab7ad82365449a042f67`. The unchanged Image SHA-256 was `4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1`. With LLVM 21 the fixture VHCI module had SHA-256 `ce4384a353d31d7f5380f4c119827bb0633d77c29eaa097f841c355bf069e071`. A successful single-boot run prints `Y700_VIRTUAL_HOG_PASS` or `Y700_VIRTUAL_CLASSIC_INPUT_PASS`, followed by `Y700_VIRTUAL_HID_EXIT=0`. The cold-boot runner checks the corrected root hash, requires `mkfs.ext4` on the host and prints `Y700_COLD_BOND_PERSISTENCE_PASS` after both guests pass. [Runner](../tests/bluetooth-virtual/run-qemu.sh)

The LE accessory publishes a HID report map and sends input through real GATT notifications. In the Classic guest, BlueZ's input plugin already owns both incoming HIDP ports on each adapter. The fixture uses the device-initiated connection mode and publishes a peer-specific SDP record using the guest daemon's local compatibility socket. The central input plugin stays enabled. [BlueZ HoG profile](https://github.com/bluez/bluez/blob/5.82/profiles/input/hog.c) · [Classic input server](https://github.com/bluez/bluez/blob/5.82/profiles/input/server.c) · [BlueZ virtual controller](https://github.com/bluez/bluez/blob/5.82/emulator/main.c)
