# TB320FC_PRC Dual LRA Haptics (`AW86927`)

Lenovo Legion Y700 Gen 2 (`TB320FC_PRC`) ships with **two independent X-axis linear resonant actuators (LRAs)** driven by Awinic `AW86927` haptic ICs.

## Hardware Wiring (Verified against Stock CN350 DT & Live I²C Probe)

| Channel | Linux Device / Input Name | I²C Bus & Address | Interrupt GPIO | Reset GPIO (`ACTIVE_LOW`) | Boost Target | Resonant Frequency (`f0`) |
| --- | --- | --- | --- | --- | --- | --- |
| Left | `6-005a` / `y700-haptic-left` (`/dev/input/event3`) | `&i2c11` (`i2c@a8c000`), `0x5a` | TLMM `38` (`EDGE_FALLING`, pull-up) | TLMM `39` | `8000 mV` (`vref=0x48`, conservative below stock `8500 mV`) | `170.0 Hz` (`f0_pre = 0x6a4`) |
| Right | `8-005a` / `y700-haptic-right` (`/dev/input/event4`) | `&i2c14` (`i2c@a98000`), `0x5a` | TLMM `171` (`EDGE_FALLING`, pull-up) | TLMM `142` | `8000 mV` (`vref=0x48`, conservative below stock `8500 mV`) | `170.0 Hz` (`f0_pre = 0x6a4`) |

- Device-tree overlay: [config/kernel/asphalt-haptics.dtsi](../config/kernel/asphalt-haptics.dtsi)
- Driver patch: [config/kernel/asphalt-aw86927-tb320fc.patch](../config/kernel/asphalt-aw86927-tb320fc.patch)

## Resonant Frequency Root Cause & 170.2 Hz SRAM Waveform

Upstream `drivers/input/misc/aw86927.c` hardcodes a 102-sample SRAM sine waveform at the 24 kHz SRAM playback rate (`235.29 Hz`, tuned for the Fairphone 5 LRA). Driving the Y700's `170.0 Hz` X-axis LRAs 38% off resonance produces very weak mechanical displacement despite normal `RAM_GO` playback.

`asphalt-aw86927-tb320fc.patch` extends the upstream driver with:

1. Device-tree `label` support (`y700-haptic-left` and `y700-haptic-right`) and unique `phys` strings so userspace distinguishes both actuators.
2. Configurable `awinic,boost-max-microvolt` (clamped safely to `6000..8500 mV`, set to `8000 mV` / `vref=0x48` on TB320FC).
3. Configurable `awinic,f0-hz`: when set in `150..190 Hz` (`170` on TB320FC), the driver loads a 141-sample sine waveform (`24000 / 141 = 170.21 Hz`, peak amplitude `±96`) with dynamically sized SRAM header addresses.

## Physical Verification Measurements (`hw-bringup-02`, 2026-11-22)

Both actuators probed cleanly as `AW86927 (chip_id=0x9270)`, loaded the 141-sample `170 Hz` waveform, entered `GLBRD5=0x07 (RAM_GO)` during Linux `FF_RUMBLE` (`EVIOCSFF`) playback, returned cleanly to standby (`DONEI=1`), and reported **zero fault interrupts (`AW86927_FAULTS=0`)**.

Physical acoustic verification recorded simultaneously through the tablet's two internal 48 kHz `WCD9385` microphones (`ch0 = AMIC1`, `ch1 = AMIC4`) confirmed both strong resonant output at `170.2 Hz` and clear Left/Right spatial isolation:

| Test Condition | `ch0` (`AMIC1`) `170.2 Hz` Goertzel | `ch1` (`AMIC4`) `170.2 Hz` Goertzel | `ch0` / `ch1` `340.4 Hz` 2nd Harmonic | Dominant Mic | AW86927 Faults |
| --- | ---: | ---: | ---: | --- | ---: |
| Quiet Baseline | `0.1` | `0.1` | `0.1` / `0.0` | — | `0` |
| Left Motor Only (`event3`, 800 ms) | `133.8` (`+62.5 dB`) | `196.7` (`+65.9 dB`) | `6.8` / `21.6` | `ch1` (Left side) | `0` |
| Right Motor Only (`event4`, 800 ms) | `266.6` (`+68.5 dB`) | `209.0` (`+66.4 dB`) | `11.2` / `17.8` | `ch0` (Right side) | `0` |

### Remaining Acceptance

- Hands-on tactile feel check by the owner (left vs. right perceived strength and sharpness).
- Desktop / game haptic feedback integration (`evdev` force-feedback consumers).
