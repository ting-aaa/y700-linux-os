# PM8350C BOB voltage request on the Y700

This observer reads the APPS power controller's current `bobc1` voltage setting once. The TB320FC PRC device tree identifies `/soc@0/rsc@17a00000/regulators-1` as the PM8350C regulator provider. Its parent is `apps_rsc`. The module takes the locks of both devices, checks their bound drivers and resolves `bobc1` using the device’s own command database. The supported board returns VRM address `0x40300`. The voltage field is at offset zero, bits 12:0 in millivolts. During a read the RPMh core skips the wake/sleep vote cache, clears the TCS write bit and reads the command response. This is a transaction with the APPS resource controller. A voltage at the PMIC output pin would require independent measurement. [Regulator field and cache](https://github.com/torvalds/linux/blob/v7.3/drivers/regulator/qcom-rpmh-regulator.c#L257-L287) · [RPMh read](https://github.com/torvalds/linux/blob/v7.3/drivers/soc/qcom/rpmh.c) · [RSC command encoding](https://github.com/torvalds/linux/blob/v7.3/drivers/soc/qcom/rpmh-rsc.c) · [Qualcomm's stated use for the APPS readback](https://lore-kernel.gnuweeb.org/lkml/20260407123652.ogirwvx7n5shrf7u@hu-kamalw-hyd.qualcomm.com/T/)

The regulator class reports a cached selector. When the cache is empty, the driver maps a positive RPMh read to the first available selector at or above that voltage. The PMIC5 table starts at 3000 mV and advances by 32 mV. The board DT requests a 3008–3960 mV range, which Linux represents as 3032–3960 mV. The previously recorded 3032 mV sysfs value cannot recover the raw resource setting. The stock normal BOB default and factory WCD supply request are 3296 mV. The active-only BOB default is 3008 mV. The four mic-bias output targets on WCD are 2700 mV each. The WCD probe enables four supplies and the ordinary SoundWire read participates in runtime PM. A rail snapshot cannot establish the voltage during cold codec enumeration. [Factory wiring, Linux drivers and cached Android variant](../../../docs/MICROPHONE.md#reading-the-chip-id-without-changing-the-shared-rail)

The retained CN350 DT names 41 ADC input channels and none is identified as BOB output. VPH_PWR is a separate net. PM8350C flash status indicates readiness and faults. It provides no calibrated voltage. PM8350C's SPMI slave ID is 2 on this tablet. The `0x40300` RPMh address must never be interpreted as an SPMI register address. [Qualcomm flash status](https://android.googlesource.com/kernel/msm/+/9ff7a030ce757458f966dc3d5ae4f557077a122b/drivers/leds/leds-qti-flash.c) · [PM8350C description](https://github.com/torvalds/linux/blob/v7.3/arch/arm64/boot/dts/qcom/pm8350c.dtsi)

## Physical sample on November 22

The real dev12.11 120 Hz kernel returned 3032 mV from the single APPS read. Regulator sysfs showed 3032000 µV both before and after. Module reference count was zero before unload and the module disappeared. Taint increased from 516 to 4612, adding the out-of-tree bit. The daily system retained the boot, seat, services and two playback endpoints. It enumerated zero SoundWire endpoints. The sample did not measure the analog BOB output or activate the codec. [Reduced evidence and log hashes](receipt.txt)

## Build and read

```sh
bash tests/microphone/bob/build.sh "$PREPARED_ASPHALT_KERNEL" "$NEW_OUTPUT"
```

Two independent ARM64 builds produced `y700_bob_read.ko` SHA-256 `3ad4f89a4c1b58bfc676136fb15e63b29c9ddae4a2fe9a471f87075c47147dbb`. The observer imports only one resource transaction function, `rpmh_read`. To take a sample, place this module and `observe.sh` in a private temporary directory and run the following command there.

```sh
sudo sh ./observe.sh ./y700_bob_read.ko
```

The wrapper checks the running kernel notes and module digest. It rejects an existing instance. Successful insertion publishes a single read-only value in `/sys/module/y700_bob_read/parameters/apps_mv`. Reading this file again returns the same sample. The wrapper requires a zero module reference count, unloads that instance and checks its removal. An unsigned external module can set persistent kernel taint flags until reboot. The wrapper prints the before/after taint values. A wrong board or resource returns `ENODEV`, a busy device lock returns `EBUSY`, and a transport error returns its errno. If cleanup reports an error, inspect the module's reference count and remove it normally when free. No service, package, mixer, regulator vote, SDW enumeration or camera operation is involved.

Both 120 Hz dev12.11 (`b103d0fc…`) and dual-refresh (`0c92b63a…`) images booted under QEMU with this exact module. Each matched its expected running kernel notes, resolved the module symbols and returned `ENODEV` on the virtual board before issuing any hardware read. An initial guest printed its shutdown message on the test receipt's last line. The final runs gave the console one second to drain and both exited cleanly. The receipts are `out/microphone/bob-apps/guest-{dev11,dual}-r2.log`.

```sh
bash tests/microphone/bob/guest-check.sh "$KERNEL_IMAGE_DIR" "$NEW_OUTPUT/y700_bob_read.ko" "$ARM64_STATIC_BUSYBOX" "$NEW_LOG"
```
