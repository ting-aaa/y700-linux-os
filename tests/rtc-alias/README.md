# Awake RTC alarm on the Y700

The board probe selects `/dev/rtc1` only when the device-tree alias, PMK8350 node, compatible, bound platform driver and `hctosys=0` all agree. Its default invocation only reads sysfs. Run the optional four-second alarm with the tablet awake, the PMK8350 already registered and system sleep inhibited. Keep this window free of other clients that can directly write the RTC's sysfs attributes. The device node itself permits a single open descriptor. Linux provides no atomic compare-and-set between a device ioctl and a concurrent privileged sysfs writer. [Linux RTC interface](https://docs.kernel.org/admin-guide/rtc.html) · [RTC sysfs implementation](https://github.com/torvalds/linux/blob/v7.3/drivers/rtc/sysfs.c)

```sh
aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra -Werror -s \
    tests/rtc-alias/awake-alarm.c -o awake-alarm
./awake-alarm
sudo systemd-inhibit --what=sleep --mode=block --why='PMK8350 awake alarm measurement' \
    ./awake-alarm --awake-alarm
```

The alarm uses time read from the RTC. The result includes signed system-minus-RTC offsets in milliseconds before and after it fires. The RTC reports whole seconds, so the short interval cannot establish long-term oscillator drift. A pass requires exactly one `RTC_IRQF|RTC_AF` event from `poll` and `read`, an increment of one on the PMIC driver's `pm8xxx_rtc_alarm` interrupt line, the expected RTC time, and restoration of the original disabled timestamp. The check leaves both clocks running continuously. This measures the awake interrupt path. Suspend wake, timed power-on, and battery drain require separate measurements. [PM8xxx alarm driver](https://github.com/torvalds/linux/blob/v7.3/drivers/rtc/rtc-pm8xxx.c)

An enabled alarm, an occupied descriptor, or a disabled nonzero alarm time prevents the measurement. Linux 7.3.4's `RTC_WKALM_RD` reports the AIE timer and supplies zero for `pending`. This interface exposes no independent PMIC latch status. The probe also checks for a readable event and samples the actual interrupt count. If interrupted, it compares the current target before restoring its own alarm. A different target is preserved. A forced process kill can leave its four-second one-shot to expire. [RTC alarm state](https://github.com/torvalds/linux/blob/v7.3/drivers/rtc/interface.c) · [RTC device ownership and events](https://github.com/torvalds/linux/blob/v7.3/drivers/rtc/dev.c)

## Reserve a twenty-second alarm for an externally controlled sleep

On the identified PMK8350, `--read-alarm` opens the RTC read-only and prints its disabled or enabled timestamp. The reservation mode sets a one-shot alarm relative to the RTC's own current seconds. A separate foreground controller can request sleep after `RTC_ALARM_ARMED` appears. An enabled alarm, a pending device event or an occupied descriptor prevents the reservation. Keep other alarm writers idle during the measured interval. The kernel exposes separate read and set operations and cannot identify two writers that happen to choose the same alarm second.

```sh
./awake-alarm --read-alarm | grep '^RTC_SAVED_ALARM ' > before
./awake-alarm --reserve-wake-alarm > alarm.log 2>&1 &
observer=$!
# The separate controller observes RTC_ALARM_ARMED and controls the sleep cycle.
wait "$observer"
./awake-alarm --read-alarm | grep '^RTC_SAVED_ALARM ' > after
cmp before after
```

The probe restores the original disabled timestamp, including a nonzero value. Catchable termination signals follow the same cleanup path. If another writer has replaced the target, its alarm is preserved and the probe exits with failure. A forced kill or power loss bypasses this userspace cleanup.

An exit status of zero verifies an alarm event and restoration. The observation reports actual `CLOCK_BOOTTIME` and `CLOCK_MONOTONIC` deltas, their difference, the kernel suspend-success delta and the first reported wake IRQ. `rtc_first_wake_irq` requires exactly one recorded suspend, a clock difference of at least one second and a matching IRQ. `other_first_wake_irq` and `wake_source_unreported` record the corresponding attribution limits. `awake_event` can be reproduced entirely without sleep. The external controller records which suspend mode it requested.

The ARM64 PL031 guest measured one alarm at 20 seconds, matched the device interrupt and reported zero time asleep. New descriptors independently confirmed restoration of a disabled nonzero timestamp after both expiry and SIGTERM. A replacement enabled by a competing writer retained its exact timestamp. The board executable refused the virtual identity. See `out/pmk8350-reserve-wake/qemu-rtc-reserve.log`.

For an attended power-button test, `--key-wake-fallback` reserves the same hardware alarm for 90 seconds. The separate [board test](../suspend/board-cycle.sh) accepts `--power-key` and requires the wake IRQ to match `pmic_pwrkey`. The automatic alarm path requires `pm8xxx_rtc_alarm`. Both compare the saved alarm from independent reads and wait for the final system suspend counter.

## Reproduce the ARM64 guest checks

```sh
bash tests/rtc-alias/run.sh --awake "$prepared_kernel" "$static_arm64_busybox" "$new_logs"
```

The isolated guest boots the 7.3.4 Asphalt kernel and a PL031 virtual RTC. A separately compiled PL031 build changes only the hardware identity, driver and interrupt label. It exercises the same Linux RTC descriptor and alarm code. Two four-second trials must deliver one alarm and one device interrupt each. The guest also checks occupied descriptors, reserved enabled and disabled times, cancellation and a competing sysfs writer replacing the test alarm. The production PMK8350 executable must refuse this virtual RTC. The legacy two-boot alias comparison remains available by omitting `--awake`. [Existing alias and routing measurements](../../docs/SUSPEND-ROUTING.md)
