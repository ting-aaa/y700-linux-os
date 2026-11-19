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

## Reproduce the radio and GATT checks

Use Windows PowerShell 5, the Windows 10/11 SDK, .NET Framework 4.8 reference assemblies, a PC radio supporting the GATT peripheral role, and WSL. The tablet probe uses Debian's system Python with PyGObject via uv. Supply the absolute WSL path to a Bash wrapper that runs commands on this tablet through authenticated, host-key-checked SSH. With no arguments the script only constructs the GATT service locally.

```powershell
powershell.exe -NoProfile -File tests/windows-ble-hid/test-profile.ps1 -TabletSshWsl $tabletSshWrapper
```

The default radio check connects, enumerates the HID attributes and disconnects. Adding `-CheckPairing` makes one pairing call and reports the type of user interaction requested. Its non-default BlueZ agent refuses consent requests. A separate `-CheckReconnect` run tests a second connection after the first closes. The fixture leaves both input reports at rest. The script checks the host pairing inventory before connecting and verifies cleanup from a second advertising process. The encrypted characteristics and static report map use the Windows GATT server API. [Host fixture](../tests/windows-ble-hid/HidPeripheral.cs) · [Tablet probe](../tests/windows-ble-hid/tablet-probe.py) · [Microsoft GATT server](https://learn.microsoft.com/windows/apps/develop/devices-sensors/gatt-server)
