# HI1339 rear-camera signal

The dev12.13 diskless AF trial measured a nearly black **processed** crop. In its last eight frames the sampled green mean was 1.7162/255. The sample fraction at or below 5 or at or above 250 was 0.9125 at a reported 33.28 ms and 16× analogue gain. These figures bound the near-white fraction below 0.48% and the near-black fraction above 90.76%, including rounding. Each unclipped sample contributes at least 6 to the mean and each near-white sample contributes at least 250. The trial reached its 664-frame limit before sending the focus command. The illumination and the RAW signal in this run are unknown. [Physical trial](CAMERA-FOCUS-PROBE.md#dev1213-physical-preview-before-autofocus)

## What the pipeline measures

HI1339 supplies 4208×3120 10-bit GBRG. The CPU ISP centres its 640×480 output at RAW offset (1784, 1320) and debayers that rectangle at native pixel spacing. The AF metric samples every third pixel across its central 320×240 region, 8,560 samples in about 0.585% of the full sensor area. The source rectangle and its one-pixel interpolation border matter when placing a target. The negotiated fourcc is 0x34324241 (AB24). On ARM64 its bytes go R, G, B, A, so the existing one-byte green offset is correct. CSI-2 RAW10 stores four upper bytes followed by one byte containing four two-bit remainders. The CPU row kernels consume the upper eight bits. The signal probe decodes all ten. [Linux RAW10 packing](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-srggb10p.html) · [CPU ISP implementation](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/software_isp/debayer_cpu.cpp) · [Sample implementation](../tests/camera-autofocus/signal-metric.h)

The pinned CN350 module declares white at 1023 and a black pedestal of 64 for each of R, Gr, Gb and B. The native HI1339 helper supplies 4096 on libcamera's 16-bit scale, equivalent to 64 on the 10-bit scale. CN350 names exposure register 0x020a, analogue gain 0x0212, line length 0x0206 and frame length 0x020e. The local Android ARM64 sensor library (SHA-256 `0e1e2d4dea88eba7ff19b7f94939388759bac7d2e61c9c13dc472d88678c3adf`, virtual addresses 0x40d0–0x414c) clamps analogue gain to 1–16, encodes the integer part of `16 × (gain − 1)` and decodes `1 + code / 16`. The native control ranges and libcamera helper agree. Native line length 5,760 pixel clocks at 576 MHz gives 10 µs per line. At the default 3,332 frame lines with a four-line margin the longest integration is precisely 33,280 µs. Request metadata can confirm the reported state. The physical measurement below records one operating point. A change of illumination or exposure is needed to assess sensor response. [TB320FC maintainer's sensor driver and register tables](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0015-asphalt-sensors.patch) · [Local CN350 decoder](../tests/camera-autofocus/stock-signal.py)

## PC replay

The stock decoder also resolves two HI1339 test-pattern register tables. CN350 mode 0 writes `0b04=00fc,0c0a=0000` and mode 5 writes `0b04=00fd,0c0a=0100`. The board driver's V4L2 control list does not expose a test-pattern selector. The register tables alone do not specify what mode 5 should look like.

The fixture executed `DebayerCpu::configure/start/process/stop` from the release's ARM64 libcamera under QEMU user emulation. Each synthetic test fills an aligned centre rectangle, leaves the surrounding sensor area bright and adds 20 bytes of row padding. An independent four-level mosaic checks the order of the two green photosites. The transfer for the four rows below used the HI1339 black pedestal, unit white-balance gains, gamma 0.5, unit contrast and disabled CCM. The normal AF metric read the resulting green channel. [ARM64 replay source](../tests/camera-autofocus/signal-isp.cpp)

| RAW R, G, B (10 bit) | Processed R, G, B (8 bit) |
| --- | --- |
| 0, 63, 64 | 0, 0, 0 |
| 803, 402, 133 | 223, 150, 67 |
| 64, 1023, 67 | 0, 254, 0 |
| 1023, 64, 1023 | 254, 0, 254 |

This exercises the released debayer, crop, black subtraction, LUT and packed channels with known inputs. The QEMU fixture uses CPU-coherent anonymous memfds. The library reports `ENOTTY` for DMA-BUF sync on those descriptors. The physical probe requires successful DMA-BUF sync. Camera transport, real sensor response, automatic gains from the live IPA, and measured lens movement remain hardware questions.

The local PC receipts are `out/camera-signal/arm64-isp.log` (SHA-256 `982a2d53583c0ea1588d208083eb29b03d6450b36c6bd1f0ed4a28606dba6a6e`) and `arm64-regression.log` (`f2559bbe067548d61bab719daacf89d513b26ff033bc47f060fbd04689757a7d`). The new ARM64 probe is `out/camera-signal/y700-af-measure-signal` (`9c86901edec6bd8f4052c62a94b994bf25d439eb0ae3ded5be9b823712442df8`).

On a PC with ARM64 execution, the Debian camera SDK, the prepared source and generated includes, and the exact installed release libraries, run the following from the repository. The scripts verify the release library hashes. The synthetic test creates its working files in a temporary directory.

```sh
bash tests/camera-autofocus/check-signal-isp.sh "$libcamera_src" "$libcamera_build"
bash tests/camera-autofocus/build-optical.sh "$libcamera_src/include" "$libcamera_build/include" ./y700-af-measure
uv run --offline --no-project python tests/camera-autofocus/stock-signal.py "$cn350_sensor_module"
```

## Physical diagnostic

The [dev12.13 USB signal receiver](CAMERA-SIGNAL-USB.md) provides an explicit host command for the paired measurement and handles recovery of the numerical receipt after disconnection.

The new probe mode `y700-af-measure --rear-signal` requests both streams. It allows 24 successful frames for warm-up, then measures precisely one RAW/RGB pair from the same request, checking both timestamps and sequence numbers. It reports exposure, gain and the four channel black levels from that request. The count, mean and fractions below and above each reporting threshold are the only scene statistics it emits. The process disables core dumps and releases both streams. It sends no focus or flash controls. Its 24-frame warm-up does not establish auto-exposure convergence. The reference tablet completed the paired measurement below.

For a future diskless trial, place a stationary, evenly lit target with distinct light and dark detail across the centre. Record the lighting condition along with the numbers. For comparison with the 664-frame trial, check the actual per-frame gain and exposure. The usual AF trial remains available separately. [Optical trial environment](../tests/camera-autofocus/optical.md)

| Paired observation | What it localizes |
| --- | --- |
| Both RAW green sites have substantial signal above their reported pedestals, yet processed green is near zero | Inspect that frame's ISP black subtraction, gains, tone response and buffer handling. |
| RAW green is already clustered at its pedestal and RGB is dark | The weak signal is present before debayering. The light reaching the lens, sensor integration, sensor readout and CSI reception are still candidates. A controlled change of illumination can discriminate among them. |
| The RAW green sites or other colour channels disagree strongly on a neutral target | Recheck CFA phase, per-channel data and readout against the matched RGB values. |
| RAW and RGB both show usable signal | The old near-black condition did not recur under these conditions. AF still requires its own stability and sharpness trial. |

## Physical paired frame on 22 November

The reference PRC tablet booted the dev12.13 signal receiver from RAM with UFS and microSD disabled and no swap. It paired sequence 24 by request timestamp after the 24-frame warm-up. Reported integration was 14.160 ms at 1× analogue gain. The table covers only the sampled centre of the frame. Illumination was unmeasured.

| RAW site | Samples | Mean (10-bit) | At or below black level 64 |
| --- | ---: | ---: | ---: |
| R | 2,160 | 64.0074 | 88.19% |
| Gr | 2,120 | 64.0208 | 86.84% |
| Gb | 2,160 | 63.9986 | 88.10% |
| B | 2,120 | 64.0009 | 86.75% |

All four sites had zero near-white samples. The three processed channels each averaged 0/255 across the 8,560 sampled positions. At this exposure the sampled signal was already at the black level before debayering. Whether the lens received enough light, and how the sensor responds to a known change in light or exposure, remain open. The earlier 664-frame run used different exposure and gain. No focus command was sent and no image was saved or transferred.

The rear sensor returned to runtime suspend. After receipt acknowledgement the tablet rebooted into its original dev12.11 kernel. Both ext4 filesystems were writable with zero recorded errors and passed a 4 KiB write, fsync and direct readback. The 1,248-package inventory matched and the display manager, SSH, NetworkManager and Bluetooth were active. The local receipts are `out/camera-signal/physical-nov22/signal.log` (SHA-256 `ca7f5d8eadaa716ee9824814691d9786ba31b20a5c7ce882ae88124498348d88`) and `daily-return.log` (`190bb6fdfe6b544b762abbb7128a22dd4bf0af3dbaa79f4433ebe57e68a2041d`).
