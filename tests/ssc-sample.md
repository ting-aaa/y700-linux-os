# Finite SSC sensor acceptance

Build the probe on Debian 13 against the same `libssc-dev` and `libssc2` used by the reviewed SSC layer. Use a native ARM64 build or a matching ARM64 sysroot for the tablet binary.

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror tests/ssc-sample.c -o ssc-sample \
    $(pkg-config --cflags --libs libssc)
```

Run it after separately checking that SLPI, the FastRPC listener and its QRTR service are up. The probe uses one libssc subscription at a time and does not change any service, registry, calibration or power settings. Its `COUNT` defaults to five for axis and heading data and one for light and proximity. `DEADLINE_SECONDS` defaults to 12 and includes discovery, subscription and sampling. A separate bounded close follows the sampling window.

```sh
for sensor in accelerometer gyroscope magnetometer light proximity compass; do
    status=0
    ./ssc-sample "$sensor" || status=$?
    printf 'exit=%s\n' "$status"
done
# For an on-change check, move a finger away from and over an available sensor.
./ssc-sample proximity 2 20
```

Keep the final `SSC_RESULT` and its `SSC_SAMPLE` rows for each sensor. `SSC_DISCOVERY status=found` means the library initialized a provider. `available=yes` follows an acknowledged open, which can still produce zero samples. The probe uses that acknowledgment because the Boolean availability getter in libssc 0.4.4 is declared as a string property. `status=ok` requires exactly the requested finite samples, an acknowledged subscription and an acknowledged close. `no-data` and `insufficient-data` are failures even though discovery succeeded. `subscribed=no` can occur when a discovered channel never sends the configuration event or first sample used by libssc to acknowledge opening. `unavailable` means discovery completed without an available sensor. `discovery-error` and `discovery-timeout` leave availability unknown. Exit codes are 0 for acceptance, 2 for usage, 3 for discovery failure or unavailability, 4 for too few valid samples, and 5 for an open or close failure. The process also has a hard alarm beyond the ordinary deadline and close grace.

| Argument | SSC data type | Sample fields |
| --- | --- | --- |
| `accelerometer` | `accel` | Three axes in m/s² |
| `gyroscope` | `gyro` | Three libssc velocity values |
| `magnetometer` | `mag` | Three magnetic field axes in µT |
| `light` | `ambient_light` | Nonnegative lux |
| `proximity` | `proximity` | `value=1` for near or `value=0` for far |
| `compass` | `rotv` | Heading in degrees computed by libssc from the rotation-vector report |

Each timestamp is monotonic Linux receipt time in microseconds. libssc 0.4.4's typed public measurement signals omit the firmware timestamp and accuracy, so this probe cannot measure sensor latency or calibration. Upstream 0.4.4 labels gyro velocity `m/s` in its CLI and proto. The probe preserves the three numeric values as `ssc_gyro_axis` without assuming a unit or axis calibration. Compass is a separate fused heading and can be unavailable even if magnetometer axes work. For a physical motion or on-change check, vary the input and compare the sample values.

The integration fixture exercises the exact Debian 13 ARM64 pipe over an isolated virtual QRTR endpoint. `ssc-sample-qrtr.sh` drives the upstream libssc 0.4.4 mock. `ssc-sample-mock.py` adds a gyroscope with an initial NaN and a light channel that acknowledges enable while withholding all measurements. The standard upstream fixtures supply the other positive reports. Physical sampling requires the actual board.
