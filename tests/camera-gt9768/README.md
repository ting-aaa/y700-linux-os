# TB320FC rear lens kernel candidate

The optional kernel adds a GT9768 lens entity for the CN350 TXD HI1339 assembly. It builds on the measured LDO5 camera-supply change. A `lens-focus` phandle makes the existing V4L2 sensor notifier attach the lens to HI1339. The normal build without `--lens` still produces the supply-only candidate.

```sh
sudo bash scripts/build-camera-ldo5.sh --lens "$PREPARED_KERNEL" "$NEW_CANDIDATE"
bash tests/camera-gt9768/run.sh "$PREPARED_KERNEL" "$NEW_CANDIDATE" "$ARM64_BUSYBOX" "$NEW_QA"
```

The build uses a private kernel-tree overlay and checks the starting image, source, kernel configuration and symbols. It independently compiles the expected DT changes from the original board source. The provided C file and DTS fragment are the additional build inputs. [Lens driver](../../config/kernel/asphalt-gt9768.c) · [Board wiring](../../config/kernel/asphalt-gt9768.dtsi)

## Power, calibration and controls

The lens locates its HI1339 supplier on the same I²C adapter through the sensor's reference to this exact node. A managed device link orders unbinding. A runtime-PM reference to the sensor runs the full tested sensor power sequence, including WL2864C LDO5. The driver also claims the documented BOB VAF supply with the stock 70 mA load vote. This reuses the measured board configuration without assigning guessed VCM pins to the sensor rails. [Board power measurements](../../docs/CAMERA-FOCUS-PROBE.md) · [Kernel device links](https://docs.kernel.org/driver-api/device_link.html)

At probe the driver reads GT9768 register 0x00 and checks for 0xe9. It reserves the EEPROM address while it reads 11 bytes from 0x0027, checks CRC-16/UMTS and validates two strictly increasing factory 10-bit codes. A busy EEPROM address, unexpected chip ID, transfer error or invalid calibration prevents registration. The V4L2 control range uses these raw per-unit infinity and macro values with step 1. The ordinary Android margin expansion is outside this candidate's control range. No calibration bytes or values go into the kernel log. A failed lens probe can leave the camera receiver waiting for its firmware-described lens. The original camera entry remains the fallback. [Factory layout and stock commands](../../docs/CAMERA-FOCUS-FLASH.md)

Opening the subdevice, enumerating controls and reading the cached control state request no actuator initialization or position change. The advertised default is the lower endpoint. Focus adjustment requires an explicit `V4L2_CID_FOCUS_ABSOLUTE` set, including for that default. The first set in a powered session performs the three CN350 initialization writes and waits for ready register 0x05. A successful request sends one big-endian target at 0x03, then allows the stock 7 ms settling interval. The driver keeps its power votes until the last lens file closes. The application can close its lens fd when the camera stops. Control errors, unbind and system suspend also release the votes. Resume and close send no park or restore command. The V4L2 control reports the last accepted request, without motor feedback.

## Diskless ARM64 test

The QA runner boots the candidate's actual kernel executable in QEMU. The guest fixture supplies a synthetic I²C adapter, PM supplier, VAF and V4L2 receiver. The built-in production lens driver handles the fake registers, reads the EEPROM bytes, registers its subdevice and serves actual control and media-controller ioctls. Its test calibration uses 128 and 512. The receiver has no pixel stream.

The guest performs a complete open, range query, cached position read and close on two file descriptors. After 250 ms idle the bus must have counted one ID read, one EEPROM read and zero writes. A separate explicit write equal to the default must initialize the actuator and send the DAC target. The guest checks the sensor power reference and the regulator's actual sysfs use count across intermediate and last closes.

The remaining cases cover a busy timeout, a failed DAC transfer, subsequent recovery, range enforcement, unbind with an fd open, stale-fd rejection, bad ID, bad CRC, reversed CRC-valid endpoints and a fresh link following rebind. The synthetic bus rejects transfers while its sensor is suspended and counts commands outside the calibration range. Removing the supplier while a requested position is active must release VAF, detach the lens, and leave its stale fd unusable. The guest does not measure physical displacement, optical focus, electrical settling, system sleep or autofocus.

The 2026-11-21 run passed on ARM64 kernel SHA-256 `b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625`. The board DTB SHA-256 is `a178f9de454d0e8aa5b474c91b4280da3aadc6aad0622c0120661447d836209f`, and the ELF notes SHA-256 is `35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6`. The guest used its own synthetic DT. In the local checkout, `out/camera-gt9768-final/guest.log` retains the results, including the deliberate probe refusals followed by successful rebind.
