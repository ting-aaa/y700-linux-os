# Main-camera actuator and EEPROM on the physical Y700

On the TB320FC_PRC running kernel `7.3.4-asphalt-prc`, the main HI1339 sensor had already reported its chip ID `0x1339` and produced full-resolution images. Its focus actuator and calibration EEPROM are separate I²C devices. The CN350 TXD module description selects GT9768 address `0x0c` and EEPROM address `0x58`. The upstream GT9768 proposal expects `0xe9` at register `0x00`. With the third factory slot-0 supply enabled, the installed tablet returned that ID and a valid per-unit AF calibration block. [Physical capture](CAMERA-SENSORS.md) · [Stock layout and supply evidence](CAMERA-FOCUS-FLASH.md) · [MediaTek GT9768 ID register](https://lists.infradead.org/pipermail/linux-mediatek/2024-June/080166.html)

## What the physical bus returned

### Installed dev12.10 clock comparison

On 2026-11-21 the installed CN350 tablet booted a counted CCI0 clock-only entry, using its permanent kernel and root. The active CCI0 source and branch changed from 19.2 MHz to **37.5 MHz**. Both returned to 19.2 MHz after the test. Both CCI0 masters worked at sensor probe on all three boots. The sensor driver read HI1339 ID `0x1339` and S5K4H7 ID `0x487b`. These are hardware register reads made by the sensor driver. The clock values come from the kernel clock framework. The SCL waveform was not measured. [Sensor ID proof](CAMERA-CCI-ID.md) · [Clock measurement](../tests/camera-cci-clock.sh)

| Fixed register request on the tablet | 19.2 MHz default | 37.5 MHz trial |
| --- | --- | --- |
| Lens ID at `0x0c`, main camera idle | Queue 0 NACK | Queue 0 NACK |
| Same ID, main sensor runtime-powered | Queue 0 NACK | Queue 0 NACK |
| EEPROM AF window at `0x58`, main sensor runtime-powered | Queue 0 NACK | Queue 0 NACK |

In all six requests CCI returned `-ENXIO` from queue 0 and never submitted queue 1. During each sensor power hold the regulator framework reported one user each for LDO1 (1.1 V) and LDO4 (2.8 V). LDO5 remained disabled with zero users. All three outputs returned to their initial states. Matching the stock controller reference frequency alone did not restore either peripheral. [Timing data and controller rate changes proposed upstream](https://lore-kernel.gnuweeb.org/lkml/asN3BRj7RyB1_Iwu@zenone.zhora.eu/T/)

### Installed dev12.10 slot-0 power comparison

A second counted boot used the original 19.2 MHz CCI clock and the original split-queue driver. Only the main sensor gained a third WL2864C supply. The sensor driver takes this regulator through the same runtime-PM transition as its existing supplies. The regulator was already configured for 2.8 V. The PC built identical ARM64 kernel, DTB and kernel notes twice. The resulting kernel retained the installed configuration, release string and exported symbols. An ARM64 guest booted it through to userspace, and the tablet subsequently booted the same kernel. [Kernel builder](../scripts/build-camera-ldo5.sh) · [Counted entry](../tests/installed-trial/README.md)

| Request on the physical tablet | LDO5 reported state during request | Response |
| --- | --- | --- |
| GT9768 ID, HI1339 suspended | Disabled, zero users | Queue 0 NACK |
| GT9768 ID, HI1339 runtime-powered | Enabled, 2.8 V, one user | Register `0x00` returned `0xe9`; queues 0 and 1 both succeeded |
| AF EEPROM, HI1339 runtime-powered | Enabled, 2.8 V, one user | All 11 bytes read, factory CRC valid, infinity and macro endpoints ordered and within the 10-bit range |

After each powered request LDO1, LDO4 and LDO5 returned to zero users and disabled. The per-unit bytes stayed on the tablet. The experiment identifies a missing supply in the native main-camera power sequence. The physical connection from LDO5 to each component has not been traced. Motor motion, optical focus, flash and application control require separate evidence.

The separately built camera-supply EFI image pairs this kernel and device tree with the original dev12.10 root. After returning to the permanent desktop, a media-controller-only topology query found the HI1339 sensor and zero lens entities. Its runtime-active time stayed unchanged. Exposing the GT9768 as a V4L2 lens is the next step before the camera application can control it. [Candidate EFI image and boot checks](CAMERA-SUPPLY-ESP.md) · [Media graph check](../tests/camera-lens-graph/README.md)

Both trial entries were removed after returning to the permanent dev12.10 kernel. Its physical outer EFI partition again had the original 29 files. All hashes matched before and after each trial apart from the boot manager’s random seed. The graphical login, touchscreen, Bluetooth service and both Wi-Fi gateway checks passed on return. The board log manifest is `out/cci0-dev12.10-board/BOARD-SHA256SUMS`, SHA-256 `1ff5cec1ac476438b36c5652db73989e865f112d38bd87756d521315eafbf1ef`.

### GT9768 lens candidate

The subsequent GT9768 kernel candidate registers a V4L2 lens and uses the sensor's factory focus interval. The ARM64 guest exercised the real driver with a simulated I²C device. Opening and querying the lens and closing the final descriptor produced zero bus writes, while an explicit position request exercised initialization and a bounded DAC write. Two independent builds reproduced the kernel, device tree and notes. A separate ARM64 EFI test booted the single-count entry and returned to the existing recovery entry on the next boot. These tests used a simulated lens. [Driver and test results](../tests/camera-gt9768/README.md) · [Single-boot EFI fixture](../tests/installed-trial/README.md)

### Earlier observations on the original installation

Linux identified `cci@ac15000/i2c-bus@0` as `Qualcomm-CCI` adapter 0, configured for 400 kHz. HI1339 was bound at `0x20`. Before each test regulator sysfs reported BOB enabled at 3.032 V and camera I/O enabled at 1.800 V. These are regulator readings reported by the kernel. Voltage at the lens connector was not measured.

| Device and operation | HI1339 state | Result |
| --- | --- | --- |
| GT9768, SMBus byte-data read of register `0x00` at `0x0c` | Suspended | `ENXIO`, no ID byte |
| Same ID read | Active under the existing sensor driver's runtime PM | `ENXIO`, no ID byte |
| EEPROM, set the 16-bit read pointer to `0x0027` at `0x58` and request eleven bytes | Active under the same runtime PM | `ENXIO`, no bytes available for CRC or endpoint validation |

Every trial ran on the current Debian installation and ended with CCI and HI1339 suspended. In the powered trials the owning HI1339 driver controlled supplies, reset and MCLK. Its separate stream routine programs capture. No frames, focus position writes or flash commands were issued. A separate transient timer was armed before each power override, and ordinary cleanup restored automatic power management. Boot, local session, backlight setting and the LightDM, SSH, Bluetooth and NetworkManager service instances matched before and after. [Asphalt sensor power and stream routines](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0015-asphalt-sensors.patch) · [Linux runtime power management](https://docs.kernel.org/power/runtime_pm.html)

The CCI interrupt handler maps a master queue NACK to `ENXIO`. The error alone cannot identify the failing transfer phase or prove a component is absent. Both reads failed with the sensor's current native rails and clock requested. A working HI1339 image stream and a decoded factory calibration format still leave physical lens identification, per-unit limits and autofocus open. [Qualcomm CCI transfer implementation](https://code.googlesource.com/linux/torvalds/linux/+/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/i2c/busses/i2c-qcom-cci.c)

The original CN350 manufacturing partition capture passed its manifest identity and content checks. A read-only directory listing showed no top-level name matching camera, CamX, EEPROM or focus. This narrow check did not locate a second source for this tablet's calibration. The hardware receipts are in `out/camera-focus-id/physical.txt`, `physical-powered.txt` and `physical-af.txt`.

## What the CN350 drivers do differently

The stock slot 0 sensor, actuator and EEPROM all select master 0 beneath `/soc/qcom,cci0@ac15000` with parent `cell-index=0`. CN350 `camera.ko` reads the child `cci-master` and parent `cell-index` when constructing the actuator and EEPROM CCI clients. The native sensor uses the bus numbered `reg=0` on the same MMIO block. Both device trees define GPIO110/111 as `cci_i2c` at 2 mA with pull-up in the active state and pull-down in the sleep state. Android selects pinctrl states per master when initializing and releasing CCI. The native runtime callbacks manage clocks and controller registers without explicitly selecting a pinctrl state. Both describe MCLK0 on GPIO100 at 24 MHz, reset on GPIO25 and 1.8 V camera I/O enable on GPIO122. The stock active MCLK pin drive is 6 mA and native is 2 mA. The stock sensor sleep state explicitly pulls MCLK and reset down. The Linux adapter number is a runtime enumeration. [Pinned DTB comparison](../tests/camera-focus-board.sh) · [Qualcomm actuator client parser](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/blob/877203a7cf9b79973d44a9db716490f95d820110/vendor/qcom/opensource/camera-kernel/drivers/cam_sensor_module/cam_actuator/cam_actuator_soc.c#L38-L60) · [Qualcomm EEPROM client parser](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/blob/877203a7cf9b79973d44a9db716490f95d820110/vendor/qcom/opensource/camera-kernel/drivers/cam_sensor_module/cam_eeprom/cam_eeprom_soc.c#L313-L337) · [Qualcomm CCI pinctrl selection](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/blob/877203a7cf9b79973d44a9db716490f95d820110/vendor/qcom/opensource/camera-kernel/drivers/cam_sensor_module/cam_cci/cam_cci_soc.c#L10-L40)

### WL2864C output 5

CN350 has a separate `qcom,ic_power` client on CCI1 (`ac16000`) master 0. The shipped module sets its 7-bit SID to `0x29` at `.text+0x15d96c`–`0x15d978`. It enables PM8350C L4 and the GPIO122 supply when binding this component. Stock slot 0 HI1339 and EEPROM use the same reset, VIO, custom L4, VANA, VDIG and MCLK command tables. In the shipped `cam_sensor_core_power_up`, power types `3` (`cam_vio`) and `7` (`cam_v_custom2`) dispatch `cam_power_ldo_control(0, 1)` at `.text+0x1599f8`. The native sensor requests its I/O supply, PM8350C L4, WL2864C LDO4 and LDO1 in that order, then starts MCLK and deasserts reset. [Stock table decoder](CAMERA-FOCUS-FLASH.md#txd-eeprom-focus-calibration) · [Qualcomm power sequence enum](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/blob/877203a7cf9b79973d44a9db716490f95d820110/vendor/qcom/opensource/camera-kernel/drivers/cam_sensor_module/cam_sensor_utils/cam_sensor_cmn_header.h#L96-L111) · [Asphalt wiring and regulator implementation](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0016-asphalt-camera-wiring.patch)

With the other slots idle, the slot 0 enable table writes register/value pairs `03:28`, `06:80`, `07:80`, `01:2f`, `0e:19` to WL2864C. The table relocation at `.data+0x9bb50` resolves to `.data+0x9bce8`. The call at `.text+0x15d260` writes its five entries. Selection registers `03`, `06` and `07` correspond to LDO1 at 1.100 V, LDO4 at 2.800 V and LDO5 at 2.800 V. The enable register `0x0e` receives `0x19` with only slot 0 active. With other cameras enabled, `0x39`, `0x1f` and `0x3f` also preserve bit 4 for LDO5. The symmetric slot 0 teardown calls `cam_power_ldo_control(0, 0)` at `.text+0x15a940`. The table at `.data+0x9bcd8` writes `0x0e` with `0x00` when the others are idle, or `0x06`, `0x20`, `0x26` according to their state. All clear bit 4. The exact module SHA-256 is `2b6cb5e0d65e0ba8fe53bdd6f51be69d2ced00025beea75cb0b7e68f3d247c72`. [Native WL2864C register mapping](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0016-asphalt-camera-wiring.patch)

`cam_eeprom_power_up` calls the same power core at `.text+0x142d54` before initializing its own CCI client at `0x142dbc`. It passes the EEPROM node's own slot 0 `soc_info` and power table. Teardown calls the shared power-down code at `0x1434e8`. The actuator passes its VAF-only sequence to the same core at `0x124748`. Its DT declares no logic-supply GPIO. This establishes the extra stock slot 0 power request and its teardown. The endpoint of LDO5 on the assembly and whether it powers the actuator or EEPROM remain unknown. On Linux, the LDO5 node exists at 2.8 V without a HI1339 consumer. The later idle readback in `out/awake-wake-clock/camera-idle-rails.log` found `camera-ldo5` disabled with zero users. [Stock actuator power table](CAMERA-FOCUS-FLASH.md#main-camera-lens-controller)

### Controller clock and transfer shape

CN350 explicitly requests a 37.5 MHz CCI source. Its Fast-mode timing fields, including SCL stretching disabled, match the native `cci_v2_data` Fast profile. The pinned Linux CCI0 DT has no rate assignment and the driver only enables clocks. The SM8450 CAMCC table supports 19.2 and 37.5 MHz. A passive read found both controllers suspended and their source and branch clocks reporting 19.2 MHz with zero enable counts. Reading the regulator state then woke CCI1, which still reported 19.2 MHz with nonzero counts, while CCI0 and HI1339 remained suspended. The receipts are `out/awake-wake-clock/camera-idle-clocks.log` and `camera-idle-rails.log`. [Qualcomm CCI timing and clock series](https://lore-kernel.gnuweeb.org/lkml/asN3BRj7RyB1_Iwu@zenone.zhora.eu/T/) · [SM8450 CAMCC rate table](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/clk/qcom/camcc-sm8450.c#L863-L880)

The shipped `cam_cci_read` builds `WRITE_DISABLE_P` (`0x0b`) at `.text+0x129a10` and `READ` (`0x0a`) at `0x129a5c`, then enqueues both to the same master and queue. The native 7.3.4 driver runs a normal `WRITE` in queue 0, waits for completion, then submits a separate `READ` in queue 1. This applies to both the emulated SMBus register read and the EEPROM `I2C_RDWR` request. The native driver does not preserve the combined repeated-START transaction. The earlier read receipts contained no phase attribution. The later queue trace below covers the idle actuator ID read. [Qualcomm combined read commands](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/blob/877203a7cf9b79973d44a9db716490f95d820110/vendor/qcom/opensource/camera-kernel/drivers/cam_sensor_module/cam_cci/cam_cci_core.c#L1098-L1146) · [Linux CCI message loop](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/i2c/busses/i2c-qcom-cci.c#L395-L449) · [Linux I²C combined transfer](https://docs.kernel.org/i2c/i2c-protocol.html#combined-transactions)

## Physical CCI0 clock and queue results

With the existing Debian kernel, a brief runtime-PM hold on `ac15000.cci` enabled the CCI0 clock branch and its source. The clock framework reported **19,200,000 Hz for both**. The branch enable/prepare counts rose from 0/0 to 1/1, and the source reached 2/2. Both returned to 0/0 after restoring automatic PM. HI1339 stayed suspended and MCLK0 stayed disabled at every sample. This measures the controller clock reported by Linux. SCL at the camera connector still requires an electrical measurement. [Controller-only test](../tests/camera-cci-clock.sh) · [Linux runtime PM](https://docs.kernel.org/power/runtime_pm.html)

A separate read of the GT9768 ID register at `0x0c` used the same native SMBus byte-data operation as the earlier test. A private trace recorded just the calling thread's queue number, master and signed return value. A standard read of the WL2864C regulator state supplied a positive control on the other CCI controller.

| Operation on the running tablet | Prefix submission, queue 0 | Read submission, queue 1 |
| --- | --- | --- |
| WL2864C regulator state on CCI1, master 0 | 0 | 0 |
| GT9768 ID with HI1339 suspended on CCI0, master 0 | −6 (`ENXIO`) | Never submitted |

The live kernel notes matched the retained `vmlinux` notes. Its disassembly places the observed queue 0 return address `cci_xfer+0x344` after the normal write submission and `+0x220` after the read submission. This separates the write from the earlier queue-validation calls. The first failed phase includes the slave address and register prefix. The trace cannot distinguish which byte the device rejected. There is no corresponding queue attribution for the earlier powered lens or EEPROM reads. The test took no picture and left the original seat, backlight and service instances intact. Terminating a separate trace process before any I²C request also verified that the 30-second recovery timer removes the private instance and both kernel events. The physical receipts are in `out/camera-cci-clock/`. [Queue probe](../tests/camera-focus-probe.py) · [Kernel trace event fields](https://docs.kernel.org/trace/kprobetrace.html)

The isolated clock candidate assigns **37,500,000 Hz** to `CAM_CC_CCI_0_CLK_SRC`. Both masters on this controller, including the front camera bus, use 400 kHz Fast mode. The native Fast timing table and the separate CCI1 domain stay at baseline. CN350 requests Fast-mode Plus for the actuator and 400 kHz for the EEPROM, so the clock-only candidate still uses a different actuator bus mode from Android. Two builds yielded an identical 121,165-byte DTB with SHA-256 `b7364d3d493689f5d64834d22dbaa3684892fb3572bceaf653659f7486d69aea`. A comparison of the complete sorted trees found only the CCI0 clock phandle and rate assignments. The normal ARM64 Kbuild target produced the same DTB. The dev12.10 clock comparison above verified the actual branch rate and the unchanged lens and EEPROM results. [Board source change](../config/kernel/asphalt-cci0-clock.patch) · [Qualcomm rate and timing series](https://lore-kernel.gnuweeb.org/lkml/asN3BRj7RyB1_Iwu@zenone.zhora.eu/T/)

Apply the patch in a separately prepared Asphalt kernel tree and rebuild the board with its existing configuration.

```sh
git apply "$product/config/kernel/asphalt-cci0-clock.patch"
make ARCH=arm64 LLVM=1 qcom/sm8475-lenovo-asphalt.dtb
```

### Installed lens and application controls

The installed dev12.11 kernel links HI1339 to GT9768 through the V4L2 media graph. A regular user on the PRC tablet queried the installed libcamera runtime through `cam --list-controls` for each camera. The rear camera offered Auto/Manual, Start/Cancel and all four autofocus result states. The front and macro cameras exposed fixed focus. All three sensors remained suspended and their cumulative active-time counters stayed unchanged. Run the check as the ordinary desktop user. [Native runtime check](../tests/camera-lens-graph/runtime-controls.sh) · [Physical lens and calibration check](DEV12.11-VERIFICATION.md) · [Touch camera](QCAM.md)

Physical qualification covers whether the visible scene gets sharper after an explicit autofocus request and whether the sensor suspends again after the client releases it. The native supply sequence enables LDO5 with reset asserted before MCLK and releases it after stopping MCLK on power-down. [Sensor power patch](../tests/camera-focus-ldo5.patch) · [Single-shot algorithm and synthetic results](../packaging/camera-autofocus/README.md)

## Reproducing the bounded read

Use the [board probe](../tests/camera-focus-probe.py) in a maintenance shell on the supported tablet. Running it without arguments checks the board, adapter, driver, free lens address and already-enabled supplies. The device node is selected from its firmware path.

To reproduce the supply trial, start from the compiled kernel tree for the installed dev12.10 entry. The builder verifies its original image, config, device tree, symbol table and camera sources. It applies the sensor patch in a private build mount. The published output contains `kernel.efi` (`bfb74a14…`), `board.dtb` (`9546d73b…`) and `notes` (`b52f0aeb…`) with SHA-256 checksums. [Build the single-boot entry](../tests/installed-trial/README.md)

```sh
sudo bash scripts/build-camera-ldo5.sh "$prepared_dev12_10_kernel" "$new_output"
```

```sh
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py --read-id
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py --power-main --report-rails --trace-queues --read-id
```

For the EEPROM diagnostic, first run the following command on a host with its own CN350 TXD module. Supply the resulting static layout alongside the probe and `scripts/decode-camera-focus.py` in their repository locations on the tablet. Only the eleven-byte AF window is requested. Decoding stays in process memory. The success output reports CRC and endpoint-order checks. The LDO5 trial decoded the block on the tablet.

```sh
uv run --no-project --python 3.13 python scripts/decode-camera-focus.py --eeprom-layout "$module" >layout.json
# On the tablet, using the copied static layout
uv run --offline --no-project --python /usr/bin/python3 python -B tests/camera-focus-probe.py --power-main --af-layout layout.json
```
