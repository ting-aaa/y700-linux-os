# Bluetooth HID over the tablet's radio

On November 19, the WCN6855 on the TB320FC_PRC connected to a Windows 11 Pro PC advertising the standard Bluetooth LE Human Interface Device service. The PC advertised input report definitions for a keyboard and a mouse. Debian 13 used its installed BlueZ 5.82 and its ordinary login screen stayed active.

| Stage | Observed on the equipment |
| --- | --- |
| Radio discovery | BlueZ matched eight fresh marker bytes in service data for HID UUID `0x1812`. |
| LE connection and GATT | The tablet reported `Connected=true` and `ServicesResolved=true`. GATT discovery found HID Information, Report Map, HID Control Point, two Report characteristics and their two Report Reference descriptors. These checks enumerate attributes. Reading encrypted contents requires link security. |
| Pairing | Calling `Device1.Pair` for that peer reached the agent's `RequestConfirmation` callback. With the operator away, the test declined the numeric comparison and BlueZ returned `org.bluez.Error.AuthenticationFailed`. |
| Unbonded reconnect | After an explicit disconnect, the tablet rediscovered the same connectable test peer. The second `Connect` call returned, but the combined connected and services-resolved check failed within eight seconds. Automatic reconnect with a bonded accessory remains open. |
| Cleanup | Both systems retained their original pairing state. Tablet discovery ended. After the HID process exited, the tablet's HCI stream received a new manufacturer's test marker during an eight-second scan with no matching advertisement from the retired fixture. |
| Input acceptance | Bonding, keyboard and mouse input at the desktop, reconnection and resume still need an attended accessory test. |

The BlueZ HID-over-GATT profile requires bonding before it attaches a HID device. The tablet's actual pairing request establishes that numeric comparison was requested here. Microsoft documents that Windows Desktop custom pairing displays a system consent dialog even when an application implements `ConfirmPinMatch`. The test recorded the BlueZ callback. The Windows consent dialog was not observed. LightDM autologin can start a desktop for software tests. An operator can complete the Bluetooth comparison when available. [BlueZ HoG profile](https://github.com/bluez/bluez/blob/5.82/profiles/input/hog.c) · [BlueZ per-application pairing agents](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.AgentManager.rst) · [Windows Desktop custom pairing](https://learn.microsoft.com/windows/apps/develop/devices-sensors/pair-devices#custom-pairing)

## Single temporary pairing trial, November 20

The tablet was already signed in to Xfce. Its WCN6855 matched a fresh, connectable Windows HID advertisement. A per-application BlueZ agent made one `Device1.Pair` call and held the resulting numeric comparison open. At 00:05:02 China Standard Time, the Windows notification service recorded a `Windows.SystemToast.Bthprops` Bluetooth toast, event 2418. The desktop observer found no separate pairing window or independently readable Windows number. BlueZ subsequently delivered `Agent1.Cancel`. Neither endpoint confirmed a match, and the tablet received no keyboard or mouse sample.

Windows' paired endpoint inventory matched the starting inventory. BlueZ retained its prior paired, bonded and trusted device sets, with zero paired devices. Discovery ended. The original seat session and Bluetooth daemon remained active. A fresh USB check found the private runtime directory gone. Local receipts under `out/bluetooth-hid-radio/` are `one-authorized-attempt.log` (SHA-256 `5ce34af35e1be3bc0e9d2656f6021761aedd33b82c3ba114df9284bcb72ebfd0`) and `one-authorized-windows.log` (`ffc5e77d2ceaeaa47825d274325aba7f857769537f37dac15bea2841d8ac524f`).

The last confirmed stage on each system was the Linux comparison request and the Windows Bluetooth notification. The records leave the origin and reason for the eventual cancellation unresolved. Microsoft requires user consent for Desktop custom pairing. An Xfce or LightDM login cannot grant that Windows consent. [Windows Desktop pairing contract](https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/pair-devices#custom-pairing)

For an attended trial, the Windows runner requires an explicit `-RunOnce` and the host-key-checked tablet SSH wrapper. A new invocation issues a new request. If Windows displays its number, the operator can run `bash compare-displayed-code.sh "$tabletSshWrapper"` from a private WSL terminal in the fixture directory and enter the Windows value at the hidden prompt. The helper compares it to the tablet's pending number through USB. A mismatch ends the comparison. Windows controls its own acceptance prompt. The runner sends the fixed F15 press/release and one step on each pointer axis only after the bond and the tablet's exclusive input capture are both ready. [Windows runner](../tests/windows-ble-hid/test-authorized-pair.ps1) · [Tablet pairing agent](../tests/windows-ble-hid/guarded-pair.py) · [Input capture](../tests/windows-ble-hid/capture-input.py)

## Reproduce the radio and GATT checks

Use Windows PowerShell 5, the Windows 10/11 SDK, .NET Framework 4.8 reference assemblies, a PC radio supporting the GATT peripheral role, and WSL. The tablet probe uses Debian's system Python with PyGObject via uv. Supply the absolute WSL path to a Bash wrapper that runs commands on this tablet through authenticated, host-key-checked SSH. With no arguments the script only constructs the GATT service locally.

```powershell
powershell.exe -NoProfile -File tests/windows-ble-hid/test-profile.ps1 -TabletSshWsl $tabletSshWrapper
```

The default radio check connects, enumerates the HID attributes and disconnects. Adding `-CheckPairing` makes one pairing call and reports the type of user interaction requested. Its non-default BlueZ agent refuses consent requests. A separate `-CheckReconnect` run tests a second connection after the first closes. The fixture leaves both input reports at rest. The script checks the host pairing inventory before connecting and verifies cleanup from a second advertising process. The encrypted characteristics and static report map use the Windows GATT server API. [Host fixture](../tests/windows-ble-hid/HidPeripheral.cs) · [Tablet probe](../tests/windows-ble-hid/tablet-probe.py) · [Microsoft GATT server](https://learn.microsoft.com/windows/apps/develop/devices-sensors/gatt-server)

## Windows report compatibility on the dev12.8 desktop

The Windows test accessory originally advertised a relative pointer with two axes and no buttons. After a virtual bond, Linux delivered its raw movements, but Debian's udev mouse classifier requires a relative pointer to advertise a mouse button. Xorg accepted only the keyboard. The Windows fixture now advertises a single left button and keeps it released for the entire test. The board image and its normal desktop input configuration require no change. [udev input classifier](https://github.com/systemd/systemd/blob/v257.13/src/udev/udev-builtin-input_id.c) · [Windows report map and sender](../tests/windows-ble-hid/HidPeripheral.cs)

| Measured stage on two virtual controllers | Original report | Corrected report |
| --- | --- | --- |
| BlueZ 5.82, fresh LE bond, resolved HID service, both reports subscribed | Passed | Passed |
| Paired device's evdev nodes | F15 down/up, X +1, Y −1 | Same events, zero clicks |
| udev and Xorg/libinput | No mouse tag. Only the paired keyboard appeared in XInput. | One mouse tag. The keyboard and pointer appeared as separate paired sources. |
| Attended capture helper | — | Grabbed both exact devices, verified the fixed reports and exited. |
| Ordinary user's GTK window after releasing the grab | — | Received keycode 193 down/up and pointer motion (+0.307, −0.307) from the two verified sources. |

The guest used the sealed dev12.8 root (`2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511`), the Y700 kernel and two emulated controllers. Windows PowerShell compiled the WinRT fixture and exported its report map without opening a radio. A BlueZ peripheral published the bytes and sent them as GATT notifications. The old and new report map SHA-256 values were `03a62b330fd0ac49b41ff8c1873afe2e80868890a32e5bf16f1e21c0845cf10f` and `cbe7caa21c714b061d4cf0cdb93097baa738ce20a970e72aec72aa5a703ebebd`. The radio trial above stopped during pairing, before input classification. Physical input from an attended, consented accessory remains open. [Virtual guest inputs and runner](BLUETOOTH-VIRTUAL.md) · [Report validation](../tests/windows-ble-hid/verify-report.py)

To reproduce the corrected case, export the compiled fields into a new directory and pass its Linux path to the ordinary virtual HID runner. Use the six inputs and Xorg dummy package listed in the [virtual HID instructions](BLUETOOTH-VIRTUAL.md). The runner requires the corrected report and both the exclusive capture and GTK completion markers.

```powershell
powershell.exe -NoProfile -File tests/windows-ble-hid/export-report.ps1 -Directory out/windows-hid-report
```

```bash
Y700_WINDOWS_REPORT_DIR="$PWD/out/windows-hid-report" Y700_BT_ROOT_FORMAT=raw \
    bash tests/bluetooth-virtual/run-qemu.sh "${inputs[@]}" --windows-report
```

The original control used the report map and fixed movement `01 ff` from version `b84ece9` with `Y700_EXPECT_LEGACY_MOUSE=1`. The two local receipts under `out/bluetooth-hid-radio/` are `windows-original-xorg.log` (SHA-256 `29070dad4cf12f0aba8d28dc04234058d1856c2082fdffc36232e3e7854fb0f0`) and `windows-corrected2-final.log` (`b5b8cd957d71704d5a0e5047b2218d77c990ff49a93b06f7fae9291250cb6787`).
