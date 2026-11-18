# Hardware/source map — 2026-11-18

This maps source evidence and missing integration. A DT compatible or registry candidate is not proof of the populated chip or a working driver. The principal fixed reference is the [Asphalt board patch](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0006-asphalt-board-dts.patch), with the later patches listed in its [queue](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/series.nix). The local PRC build keeps this wiring while adapting region/memory.

| Function | Identified interface / source candidate | Current evidence and implementation route |
| --- | --- | --- |
| GPU | SM8475 / Adreno 730, DRM/MSM + GMU + Mesa Freedreno/Turnip | Fault unresolved; [hypothesis table](GPU-INVESTIGATION.md) |
| Panel/touch | DSI `lenovo,y700-nt36523n`; SPI `novatek,nt36523n-spi`; touch reports NT36523N | Portrait and left rotation physically accepted; upstream display/touch patches and firmware recipe |
| Backlight | I2C `lenovo,y700-ktz8866`, `kinetic,ktz8866` | DT evidence; brightness/power transitions need real measurements |
| Wi-Fi | PCIe `pci17cb,1103`, WCN6855 hw2.1 ath11k | Hotspot physically accepted; board-2 calibration and radio firmware must remain matched |
| Bluetooth | UART `qcom,wcn6855-bt` | DT/firmware route present; pairing/resume not accepted |
| Speakers | Two I2C `cirrus,cs35l45`, `lenovo,y700-sndcard` / SM8450 LPASS/ADSP | DSP/topology/UCM sources available; safe volume, routing and playback not accepted |
| Microphone/jack | ADSP audio graph; `fcs,fsa4480` Type-C switch | Exact usable recording routes and jack policy still require inventory/testing |
| Accelerometer/gyro | SSC through SLPI/SDSP FastRPC, not simply direct AP I2C | IMU registry includes LSM6DST, BMI3x0 and ICM4x6xx candidates; live sensor identity/revision unconfirmed |
| Magnetometer/light/proximity/Hall | Upstream reports MMC56x3, STK3A5x and BU52053NVX in SSC | Same-device upstream evidence only; this Debian install has no accepted readings |
| Cameras | Patched CCI/CSIPHY/CAMSS graph names HI1339, S5K4H7, SC202CS; WL2864C regulator | Source candidates; populated-module/route identification and capture still unverified |
| Video codec | SM8450 Iris/remote firmware and secure-memory patches | No hardware video encode/decode acceptance; distinct from GPU rendering |
| USB / external display | Qualcomm DWC3, QMP USB3/DP PHY, NXP eUSB2 repeater, PMIC GLINK | Existing ACM/NCM works; newly generated identity, Type-C roles and external DP need tests |
| Storage | UFS controller/SM8475 PHY and OPP patches | Internal root boot physically accepted; lifecycle/recovery and sustained I/O still separate |
| Power/charging/thermals | PM8350/PM8350C/PMR735A RPMh regulators, PMIC GLINK and Qualcomm thermal/power paths | Inventory fuel-gauge/charger interfaces and actual readings before choosing a charging policy |
| Buttons/haptics | gpio-keys; multiple vendor haptic candidates upstream | Power/volume input matrix and exact haptic device/interface remain open |

## Sensor migration finding

Fresh read-only inspection found SLPI `offline`, ADSP `running`, only `/dev/fastrpc-adsp`, no board SLPI firmware, no SSC/proxy unit, and no IIO device entries. Lack of IIO entries alone is not decisive because SSC uses a different transport. Together these observations identify missing platform inputs; they do not establish failed physical sensors.

The exact [upstream Asphalt module](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/modules/devices/asphalt/sensors.nix) selects **sdsp**. The [shared SSC module](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/modules/mobile/ssc-sensors.nix) combines FastRPC `sdsprpcd sensorspd`, writable registry state, DSP libraries, libssc and an SSC-enabled iio-sensor-proxy. Qualcomm's [daemon documentation](https://github.com/qualcomm/fastrpc/blob/development/Docs/daemons.md) explains the userspace listeners. Ordinary Android kernel modules are not replacements for this native stack.

The registry build is now executable:

```sh
bash scripts/fetch-upstream.sh # only if the pinned checkout is absent
uv run --python 3.13 --no-project python scripts/build-sensor-registry.py out/sensors-registry
```

It rejects a dirty/wrong upstream checkout and uses MTP / SoC 531 / registry version 7 exactly as the pinned recipe does. Two local runs produced the same 385 files. Every input and output hash is recorded in the ignored output. The selected defaults contain multiple IMUs, so this result **does not identify the installed accelerometer/gyro**. For example, the LSM6DST candidate says bus type 3, instance 1, slave configuration 106 and I3C address 10; those are DSP registry values, not proof that Linux should probe an AP bus at that address. Preserve existing calibration when eventually installing registry state; never reseed a live registry blindly.

The native library route is [libssc v0.4.4](https://codeberg.org/DylanVanAssche/libssc), FastRPC v1.0.7 plus the pinned Asphalt patches, and the paired [coordinate fixes](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/overlays/ssc-coordinates.nix). The Codeberg archive timed out from both build host and Windows, so no new libssc binary is claimed. A complete Debian package graph and provenance-reviewed SLPI/DSP firmware bundle remain required.

`src/sensors/y700-auto-rotate.py` adds an X11 development bridge using monitor-sensor events and the existing rollback-aware display/touch helper. It defaults to observation, debounces orientation, ignores unknown poses, honors a lock file, and delays retries after a failed mapping. Run through uv; `--apply` is an explicit future attended test. It is not included in session autostart. Software tests cover the policy, not sensor sampling or physical orientation correctness. The upstream sensor/registry test suite also passed 10 tests on Linux; none are hardware tests.

Remaining work includes licensing review, a native FastRPC/libssc/proxy build, and comparing the selected registry with this PRC revision.

The PC comparison now covers those stock inputs. The compiled Linux DT enables the SLPI node at 0x02400000 and requests `qcom/sm8475/lenovo/tb320fc/slpi.mdt`. CN350 modem.img contains that metadata, 23 binary segments and two JSON descriptors. Across those 26 files, 17 match the upstream sensor bundle and nine differ, including the MDT and eight binary segments. All seven selected SDSP listener/skeleton files from CN350 dsp.img matched their upstream counterparts. The three stock image hashes matched the retained CN350 extraction manifest. The comparison tool exports only sizes of the compared sets and hashes. Keep each SLPI image and its segments from one build; the actual IMU still requires live enumeration through the native stack. Candidate 03 preserves the existing boot baseline without enabling a new SLPI service. [Per-file hashes](research/cn350-firmware-comparison.json)
