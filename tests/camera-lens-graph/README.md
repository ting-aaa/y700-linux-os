# Inspect a camera's lens link

`lens-graph /dev/mediaN 'exact sensor entity name'` reads the Linux media-controller graph. It reports the uniquely linked lens name and its V4L2 subdevice major/minor. It checks the controller identity against sysfs, opens only that controller, and uses two `MEDIA_IOC_G_TOPOLOGY` calls. It requires a camera sensor, an enabled sensor-to-lens ancillary link and an enabled V4L2 subdevice interface for the lens. An incomplete or changing graph exits nonzero. [Kernel topology ABI](https://docs.kernel.org/userspace-api/media/mediactl/media-ioc-g-topology.html)

In the VIMC guest, adding `--query-range /dev/v4l-subdevN` opens the specified linked interface and queries only the metadata for `V4L2_CID_FOCUS_ABSOLUTE`. Opening a physical lens subdevice can itself move the actuator. For example, the DW9768 driver resumes on open, writes DAC positions on resume, and steps to zero during autosuspend after close. The range option has only been exercised against VIMC here. [DW9768 runtime power and file operations](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/dw9768.c#L240-L355)

## Reproduce on a PC

Use the prepared Asphalt 7.3.4 kernel tree, its ARM64 LLVM toolchain, static AArch64 libc and GCC, a static ARM64 BusyBox with the guest applets, cpio, gzip and QEMU system emulation. The last argument must name a new directory. The runner compiles disposable external modules from the kernel sources and boots a diskless guest.

```sh
bash tests/camera-lens-graph/run.sh "$PREPARED_KERNEL" "$ARM64_BUSYBOX" "$NEW_RESULTS"
(cd "$NEW_RESULTS" && sha256sum -c SHA256SUMS)
```

The run on kernel image `9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db` produced the following results in `guest.log`.

| Actual kernel configuration in the guest | Observation |
| --- | --- |
| Original VIMC | Sensor A linked to Lens A and Sensor B to Lens B. |
| Every V4L2 subdevice node moved out of /dev | The controller still returned the Lens A interface. |
| Explicit query on the Lens A interface | Raw integer range 0–1023, step 1, default 0. |
| Lens A interface supplied for Sensor B, or absent sensor name | Both commands failed. |
| VIMC with the ancillary link from Sensor A omitted | A failed while B still resolved. Both lens entities were registered. |
| VIMC with both lens entities and ancillary links omitted | Sensor A was found and the absent lens was reported. |

## Applying the result to TB320FC

The physical ID and CRC results establish that the original CCI configuration reaches GT9768 and the EEPROM while the rear sensor is powered and WL2864C LDO5 is active. A board driver still needs to retain the verified supplies for every actuator transaction, including when the sensor autosuspends. The successful combined power sequence leaves the individual VCM supply connections and independent operating sequence unresolved. The existing decoder checks the factory window per unit. Motion limits and park behavior require separate evidence. [Board power trial](../../docs/CAMERA-FOCUS-PROBE.md) · [Factory calibration and kernel driver comparison](../../docs/CAMERA-FOCUS-FLASH.md)

For a future board driver, the first host-visible interface to verify is an ancillary link from HI1339 to a GT9768 lens entity. Libcamera 0.7.2 discovers an ancillary lens this way and opens its subdevice during camera initialization. Its public `LensPosition` control uses dioptres, so a raw V4L2 range and two electrically valid DAC endpoints do not supply the optical calibration. The simple pipeline's focus-control and autofocus work remains open. [Libcamera sensor discovery](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/sensor/camera_sensor_legacy.cpp#L607-L621) · [Lens initialization](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/camera_lens.cpp#L52-L87) · [LensPosition definition](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/control_ids_core.yaml#L931-L952) · [Simple software IPA](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/ipa/simple/soft_simple.cpp)
