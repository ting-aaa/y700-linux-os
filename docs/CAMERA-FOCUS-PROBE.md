# Main-camera actuator and EEPROM on the physical Y700

On the TB320FC_PRC running kernel `7.3.4-asphalt-prc`, the main HI1339 sensor had already reported its chip ID `0x1339` and produced full-resolution images. Its focus actuator and calibration EEPROM are separate I²C devices. The CN350 TXD module description selects GT9768 address `0x0c` and EEPROM address `0x58`. The upstream GT9768 proposal expects `0xe9` at register `0x00`. These two peripheral addresses still need a successful physical response on this tablet. [Physical capture](CAMERA-SENSORS.md) · [Stock layout and supply evidence](CAMERA-FOCUS-FLASH.md) · [MediaTek GT9768 ID register](https://lists.infradead.org/pipermail/linux-mediatek/2024-June/080166.html)

## What the physical bus returned

Linux identified `cci@ac15000/i2c-bus@0` as `Qualcomm-CCI` adapter 0, configured for 400 kHz. HI1339 was bound at `0x20`. Before each test regulator sysfs reported BOB enabled at 3.032 V and camera I/O enabled at 1.800 V. These are regulator readings reported by the kernel. Voltage at the lens connector was not measured.

| Device and operation | HI1339 state | Result |
| --- | --- | --- |
| GT9768, SMBus byte-data read of register `0x00` at `0x0c` | Suspended | `ENXIO`, no ID byte |
| Same ID read | Active under the existing sensor driver's runtime PM | `ENXIO`, no ID byte |
| EEPROM, set the 16-bit read pointer to `0x0027` at `0x58` and request eleven bytes | Active under the same runtime PM | `ENXIO`, no bytes available for CRC or endpoint validation |

Every trial ran on the current Debian installation and ended with CCI and HI1339 suspended. In the powered trials the owning HI1339 driver controlled supplies, reset and MCLK. Its separate stream routine programs capture. No frames, focus position writes or flash commands were issued. A separate transient timer was armed before each power override, and ordinary cleanup restored automatic power management. Boot, local session, backlight setting and the LightDM, SSH, Bluetooth and NetworkManager service instances matched before and after. [Asphalt sensor power and stream routines](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0015-asphalt-sensors.patch) · [Linux runtime power management](https://docs.kernel.org/power/runtime_pm.html)

The CCI interrupt handler maps a master queue NACK to `ENXIO`. The error alone cannot identify the failing transfer phase or prove a component is absent. Both reads failed even with the sensor's normal rails and clock requested. Establish the lens/EEPROM power enable and CCI transaction path from a working stock Android operation before revising the driver or moving the lens. A working HI1339 image stream and a decoded factory calibration format still leave physical lens identification, per-unit limits and autofocus open. [Qualcomm CCI transfer implementation](https://code.googlesource.com/linux/torvalds/linux/+/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/i2c/busses/i2c-qcom-cci.c)

The original CN350 manufacturing partition capture passed its manifest identity and content checks. A read-only directory listing showed no top-level name matching camera, CamX, EEPROM or focus. This narrow check did not locate a second source for this tablet's calibration. The hardware receipts are in `out/camera-focus-id/physical.txt`, `physical-powered.txt` and `physical-af.txt`.

## Reproducing the bounded read

Use the [board probe](../tests/camera-focus-probe.py) in a maintenance shell on the supported tablet. Running it without arguments checks the board, adapter, driver, free lens address and already-enabled supplies. The device node is selected from its firmware path.

```sh
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py --read-id
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py --power-main --read-id
```

For the EEPROM diagnostic, first run the following command on a host with its own CN350 TXD module. Supply the resulting static layout alongside the probe and `scripts/decode-camera-focus.py` in their repository locations on the tablet. Only the eleven-byte AF window is requested. Decoding stays in process memory. The success output reports CRC and endpoint-order checks. The physical test above returned before decoding.

```sh
uv run --no-project --python 3.13 python scripts/decode-camera-focus.py --eeprom-layout "$module" >layout.json
# On the tablet, using the copied static layout
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py --power-main --af-layout layout.json
```
