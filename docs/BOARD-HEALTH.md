# Board health readings on TB320FC_PRC

The CPU/GPU die temperatures, Wi-Fi die temperature and PMIC GLINK battery/USB readings are available on the native Debian boot independently of the SLPI motion and ambient sensor path. [Sensor hardware map](HARDWARE-MAP.md) · [SSC measurements](CAMERA-SENSORS.md#physical-ssc-qualification)

## Capture a read-only snapshot

Run the following on the tablet or pipe the script over the verified USB SSH connection to `timeout -k 2s 30s bash -s -- 4 2`. The arguments select four samples and a two-second pause between rounds. The tool reads a fixed list of sysfs attributes. It omits serial, device identity, network metadata and sysfs `uevent` files. [Snapshot tool](../tests/board-health.sh)

```sh
timeout -k 2s 30s bash tests/board-health.sh 4 2
```

`ALIAS` rows identify thermal and power-supply channels mirrored into hwmon through the same kernel device. `DATA` records the start-of-round uptime, sysfs path, unit, value and quality. `SUMMARY` records how many readings passed the checks and whether their reported values changed. `steady` leaves freshness unresolved. `sentinel`, `alarm-default`, read failures, inactive inputs and mismatched battery power are retained in `DATA` for diagnosis. They are excluded from the valid counts. Temperature units are `mC` for millidegrees Celsius and `deciC` for tenths of a degree. Power-supply units are µV, µA, µW and µAh. `kind` separates telemetry from estimates, contract figures and software state.

## Four physical samples

The 2026-11-19 USB-attached native session used `7.3.4-asphalt-prc` and returned 292 readings across 73 attributes. The four round starts spanned 6.68 seconds. No workload or setting change was applied. All 32 on-die TSENS channels returned plausible numbers and 31 changed. Their labels cover SoC regions including CPU, GPU, camera interface, video, memory and modem. The SoC device tree maps the channels directly to `tsens0` and `tsens1` in `arch/arm64/boot/dts/qcom/sm8450.dtsi`. [Kernel source pin](../upstream.lock.json)

| Time from first sample | SoC TSENS range | USB voltage | USB current |
| ---: | ---: | ---: | ---: |
| 0.00 s | 18.3–22.0 °C | 5.074 V | 0.147 A |
| 2.21 s | 18.3–20.8 °C | 5.079 V | 0.147 A |
| 4.45 s | 18.3–20.3 °C | 5.066 V | 0.175 A |
| 6.68 s | 18.3–20.7 °C | 5.070 V | 0.137 A |

| Interface and observed path | Result and interpretation |
| --- | --- |
| `/sys/class/thermal/thermal_zone{0..31}/temp` | 32 direct TSENS channels. `gpu-top-thermal` ranged from 18.4–18.8 °C. Use each zone's `type` to identify it across boots. |
| `/sys/class/hwmon/hwmon35/temp1_input` (`ath11k_hwmon`) | 19.0 °C four times. `drivers/net/wireless/ath/ath11k/thermal.c` sends a WMI temperature request and waits for the driver's firmware reply on each successful read. |
| `/sys/class/thermal/thermal_zone{32,33,34}/temp` | PM8350, PM8350C and PMR735A each returned 37.000 °C. Live DT phandles resolve to SPMI temperature alarms with no `io-channels`. `drivers/thermal/qcom/qcom-spmi-temp-alarm.c` uses 37.000 °C initially and estimates temperature from alarm thresholds when there is no ADC. These are alarm-state values. |
| `/sys/class/power_supply/qcom-battmgr-bat/` | `Full`, 100%, 15.0 °C, 4.417 V and 0 µA in all four rounds. Charge counter and full charge both reported 5.078 Ah, with 6.550 Ah design capacity. `voltage_ocv` reported 4.41805 V as a fuel-gauge estimate. |
| `/sys/class/power_supply/qcom-battmgr-usb/` | `online=1` with changing voltage and current in the table above. `current_max` and `input_current_limit` reported 3.0 A as limits. |
| `/sys/class/power_supply/qcom-battmgr-wls/` | `online=0`. The snapshot classified residual current of 0.087–0.169 A and voltage of −0.002–0 V as inactive. A wireless supply entry alone leaves hardware support unresolved. |
| `/sys/class/power_supply/ucsi-source-psy-pmic_glink.ucsi.01/` and `.02` | The first connector was online and reported 3.0 A, while the second was offline. `drivers/usb/typec/ucsi/psy.c` derives current from the advertised Type-C mode or PD request. Its voltage property follows source capability and contract information. |
| `/sys/class/backlight/ktz8866-backlight/` | Requested and `actual_brightness` both read 102 of 2047, with `bl_power=4` (power-down). The KTZ8866 driver has no `get_brightness` readback operation, so the backlight core returns the stored setting for `actual_brightness`. Panel luminance remains unmeasured. |

The snapshot resolved 41 aliases. Linux exposes the 35 SoC and PMIC thermal zones again as hwmon, and mirrors the battery, PMIC USB/wireless and both UCSI connector supplies there. The additional battery thermal zone reads the same power-supply temperature after multiplying tenths of a degree by 100. Those aliases add zero independent sensor channels. The separate ath11k hwmon channel has its own firmware source. [Thermal hwmon](https://github.com/torvalds/linux/blob/master/drivers/thermal/thermal_hwmon.c) · [Power-supply core](https://github.com/torvalds/linux/blob/master/drivers/power/supply/power_supply_core.c)

### Battery `power_now` needs qualification

`qcom-battmgr-bat/power_now` reported 47,948,712 µW in all four rounds, alongside 0 µA battery current. The only available input observed was USB at about 0.69–0.89 W from its voltage and current readings. A later validation sample reported 47,975,692 µW at 0 µA, so the high value varies over time. The SM8450 PMIC GLINK compatible selects the battery manager's SM8350-style property path. In the pinned `drivers/power/supply/qcom_battmgr.c`, `POWER_NOW` requests firmware property `BATT_POWER_NOW` (22). The reply's little-endian 32-bit value is published directly as `power_now`. Voltage (7) and current (9) are separate requests. The driver path performs no multiplication of voltage and current for this field. The ABI unit is µW. Firmware estimation, different sample windows, property semantics and scale remain unresolved. The snapshot flags this combination as `zero-current-mismatch`. The readings were sequential, so the flag is a diagnostic hint. UPower had no active service or installed executable to compare. [Kernel source pin](../upstream.lock.json) · [Power-supply class units](https://docs.kernel.org/power/power_supply_class.html)

Temperature accuracy, calibrated power measurement, charge transitions, thermal protection thresholds, brightness transitions and suspend behavior require separate physical qualification.
