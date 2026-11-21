# Identify both CCI0 sensors without opening a camera

On the TB320FC_PRC, the rear main and front sensors use the two masters of the same CCI controller at `0xac15000`. The Asphalt driver powers each sensor during probe, reads its two-byte ID using `cci_read()`, rejects a transfer error or unexpected ID, and prints the returned value after registering the sensor. Its streaming operation programs the mode and starts the sensor separately. The driver's V4L2 interface provides no userspace get-ID operation. [Sensor driver](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0015-asphalt-sensors.patch) · [Board wiring](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0016-asphalt-camera-wiring.patch)

| Position | CCI0 master | Linux client | ID register | Physical boot read | CN350 expected ID |
| --- | --- | --- | --- | --- | --- |
| Rear main HI1339 | 0 | `0x20` | `0x0716` | `0x1339` | `0x1339` |
| Front S5K4H7 | 1 | `0x10` | `0x0000` | `0x487b` | `0x487b` |

The physical dev12.10 baseline journal records both successful reads. The driver used for this source comparison is `drivers/media/i2c/asphalt-sensors.c`, SHA-256 `90a7e501f0b57d934487d89d8944dcbfa625fa676b825acf3f34e2300c096cd5` in the prepared 7.3.4 kernel tree. Its reported value comes from the bus transaction. The CCI controller selects the master from the DT adapter's `reg` property and submits each read on that master. The actuator and EEPROM use separate addresses and have separate power requirements. [CCI controller driver](https://github.com/torvalds/linux/blob/v7.3/drivers/i2c/busses/i2c-qcom-cci.c) · [Lens and EEPROM measurements](CAMERA-FOCUS-PROBE.md)

Run the following on the boot being checked. The script joins that boot's kernel messages to both current DT nodes, bound I²C clients and their adapter and platform drivers. It reads kernel metadata without opening any bus, video or media device, or changing runtime power. If a log entry has expired or the binding differs, it exits incomplete. Each printed register value was measured during that boot's sensor probe. [Verification script](../tests/camera-sensor-board-id.sh)

```sh
sudo bash tests/camera-sensor-board-id.sh
```

CN350's `sensorDriverData` in the TXD HI1339 and Qtech S5K4H7 configuration files supplies register and data type 2 (word), write-address bytes `0x40` and `0x20`, and the respective register/ID pairs in the table. The `vendor/lib/camera` and `vendor/lib64/camera` copies matched for each sensor. Their SHA-256 values are `34ba25820a0ac983acd57075d8be57cb1b6eba55c3d315f5f7475c946149a3a8` and `0bd8585a5ce1d75f41cd4bb55eb75d288552fdd8710fb1d8f7a33f3a426f0d67` respectively. The packed records begin at file offsets `0x9870` and `0xa950`. Each has a typed sensor-name reference at offset 12 and six little-endian 32-bit values beginning at offset 44 for the address, address type, data type, ID register, ID and mask. [CamX sensor schema](https://github.com/bjzhou/CamxChi/blob/9f17f1b568626b393e785b369c5dc94543774d7a/chi-cdk/api/sensor/camxsensordriver.xsd#L8-L54) · [Parameter Parser container reader](../scripts/decode-camera-focus.py)
