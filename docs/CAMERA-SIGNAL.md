# HI1339 rear-camera signal

The dev12.13 diskless AF trial measured a nearly black **processed** crop. In its last eight frames the sampled green mean was 1.7162/255. The sample fraction at or below 5 or at or above 250 was 0.9125 at a reported 33.28 ms and 16× analogue gain. These figures bound the near-white fraction below 0.48% and the near-black fraction above 90.76%, including rounding. Each unclipped sample contributes at least 6 to the mean and each near-white sample contributes at least 250. The trial reached its 664-frame limit before sending the focus command. The illumination and the RAW signal in this run are unknown. [Physical trial](CAMERA-FOCUS-PROBE.md#dev1213-physical-preview-before-autofocus)

## What the pipeline measures

HI1339 supplies 4208×3120 10-bit GBRG. The CPU ISP centres its 640×480 output at RAW offset (1784, 1320) and debayers that rectangle at native pixel spacing. The AF metric samples every third pixel across its central 320×240 region, 8,560 samples in about 0.585% of the full sensor area. The source rectangle and its one-pixel interpolation border matter when placing a target. The negotiated fourcc is 0x34324241 (AB24). On ARM64 its bytes go R, G, B, A, so the existing one-byte green offset is correct. CSI-2 RAW10 stores four upper bytes followed by one byte containing four two-bit remainders. The CPU row kernels consume the upper eight bits. The signal probe decodes all ten. [Linux RAW10 packing](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-srggb10p.html) · [CPU ISP implementation](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/software_isp/debayer_cpu.cpp) · [Sample implementation](../tests/camera-autofocus/signal-metric.h)

The pinned CN350 module declares white at 1023 and a black pedestal of 64 for each of R, Gr, Gb and B. The native HI1339 helper supplies 4096 on libcamera's 16-bit scale, equivalent to 64 on the 10-bit scale. CN350 names exposure register 0x020a, analogue gain 0x0212, line length 0x0206 and frame length 0x020e. The local Android ARM64 sensor library (SHA-256 `0e1e2d4dea88eba7ff19b7f94939388759bac7d2e61c9c13dc472d88678c3adf`, virtual addresses 0x40d0–0x414c) clamps analogue gain to 1–16, encodes the integer part of `16 × (gain − 1)` and decodes `1 + code / 16`. The native control ranges and libcamera helper agree. Native line length 5,760 pixel clocks at 576 MHz gives 10 µs per line. At the default 3,332 frame lines with a four-line margin the longest integration is precisely 33,280 µs. Request metadata can confirm the reported state. The physical measurement below records one operating point. A change of illumination or exposure is needed to assess sensor response. [TB320FC maintainer's sensor driver and register tables](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0015-asphalt-sensors.patch) · [Local CN350 decoder](../tests/camera-autofocus/stock-signal.py)

## PC replay

The stock decoder also resolves two HI1339 test-pattern tables. CN350 mode 0 writes `0b04=00fc,0c0a=0000` and mode 5 writes `0b04=00fd,0c0a=0100`. The associated optical-black rectangle has four zero fields, so it supplies no reference pixels for this analysis. The board driver's V4L2 control list lacks a test-pattern selector. The CN350 register records do not establish a known bright output. In Samsung's public HI1339 driver, the alternative pattern write is compiled out and the active function reports the feature as unsupported. The exposure comparison below uses the driver's documented controls. [CN350 decoder](../tests/camera-autofocus/stock-signal.py) · [Samsung HI1339 implementation](https://github.com/VH-Devices/android_kernel_samsung_a24/blob/9ca068ff2a485c85841d8b1fa5da529d200df44b/drivers/misc/mediatek/imgsensor/src/common/v1_1/hi1339_mipi_raw/hi1339mipiraw_Sensor.c#L1075-L1096)

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

## Controlled exposure comparison

The separate `--rear-bracket` diagnostic measures the same centre crop at four settings during one stream. Use a fixed matte target with visible light and dark detail and independently check that the main lens is unobstructed and illuminated throughout the run. Returning to the first setting helps identify motion or illumination changes during the sequence. Rebuild the previous single-pair executable from commit `811c06f` to reproduce its sealed digest.

| Step | Exposure | Analogue gain | Comparison |
| ---: | ---: | ---: | --- |
| 1 | 2 ms | 1× | Initial reference |
| 2 | 32 ms | 1× | 16× longer integration |
| 3 | 32 ms | 8× | 8× greater analogue gain at the same integration time |
| 4 | 2 ms | 1× | Repeat the reference |

Each accepted point requires four consecutive completed requests with the intended settings and matching exposure and gain metadata. The fourth frame supplies one pair with equal RAW and RGB timestamps and sequence numbers. A point expires after 32 successful frames. The entire capture has a 60-second deadline. The client then completes four requests in automatic mode, stops and releases the camera. The receipt carries four `BRACKET_STEP` rows, each followed by one `SIGNAL_PAIR`, four `SIGNAL_RAW` rows and three `SIGNAL_RGB` rows. The final `BRACKET_DONE` is issued after successful release. All frame buffers stay in memory. [Measurement client](../tests/camera-autofocus/optical.cpp)

The released Simple IPA computes automatic exposure. Its per-frame metadata comes from libcamera's delayed sensor-control bookkeeping. A private IPA delegates metering, ISP parameters and metadata to that exact release and substitutes the **next** exposure and gain proposal only for an explicit supported manual request. It verifies the sensor model, geometry and control ranges. It does not query a hardware-embedded register readback. The test uses the normal pipeline writer and two standard V4L2 controls. [Adapter](../tests/camera-autofocus/bracket-ipa.cpp) · [libcamera delayed controls](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/delayed_controls.cpp)

Compare individual RAW channels after subtracting their reported pedestal. With stable illumination and usable unsaturated signal, a rise at step 2 and another rise at step 3, followed by a return near step 1, shows that the received data responds to both controls. Inspect ISP processing if RAW responds while matched RGB stays black. Saturation, noise near the pedestal and automatic ISP processing limit exact ratios. If all four pairs cluster at black with confirmed illumination, investigate the physical optical path, sensor control application and readout/CSI. A missing metadata match leaves that point unmeasured.

To build, use the prepared ARM64 release libraries and matching source and generated headers. The helper verifies the hashes of both shared libraries, the release IPA and its worker. Use an ordinary account inside a device-free ARM64 VM for the IPC fixture. The stock worker uses Linux namespaces through `clone3`; ARM64 user-mode emulation on this PC returned `ENOSYS`. The full-system VM supports that operation. The two environment variables used for the physical client are `LIBCAMERA_IPA_MODULE_PATH` pointing at the root-owned temporary module directory and `LIBCAMERA_IPA_FORCE_ISOLATION=1`. [Build helper](../tests/camera-autofocus/build-bracket.sh) · [Device-free IPC fixture](../tests/camera-autofocus/bracket-ipa-test.cpp)

```sh
bash tests/camera-autofocus/build-bracket.sh "$libcamera_src" "$libcamera_build" ./bracket-build
mkdir -p ./bracket-build/ipa
install -m644 ./bracket-build/ipa_bracket.so ./bracket-build/ipa/
LD_LIBRARY_PATH=/opt/y700-camera/lib timeout 20 ./bracket-build/bracket-test "$(realpath ./bracket-build/ipa)"
```

The PC full-system QEMU replay ran as UID 1000 with `no_new_privs`, without a virtual camera or disk. The release Simple pipeline selected the private module through normal discovery. In the 21-frame matching-geometry case, every frame delivered an ISP parameter event, a next-sensor-control proposal and metadata for the earlier applied settings. The automatic request restored the stock proposal. With an incompatible line length, the stock proposal passed through. A second boot repeated both cases with the current RAM receiver's diagnostic libcamera `ab1cd0e9…` first in the loader path. These tests use synthetic delayed sensor controls and anonymous statistics buffers. A physical exposure sequence remains open.

The PC receipts are `out/camera-bracket/isolated-release.log` (SHA-256 `0b0f54d7cc57bfdb0fa644eeadc4c49a59a7dac153c7495bd3ebc5d00f0f75a8`) and `isolated-ram-library.log` (`457f72774eb0230dcc00118e4a37ed531b9c3e44d69bda409ba5f14421739c6d`). A third boot with an empty module directory selected the stock IPA and failed the manual-mode check as expected (`missing-adapter.log`). Two independent builds produced identical bytes for the measurement client (`f491720d006ef35464e85e5dde184bc6fa74f548d9644d2cdbe0fd03aa5193e9`), isolated adapter (`3dcde9a32e58714e7fae70dc05e816fdb52afbc0a391e5f39e5e64eec61db87f`) and synthetic fixture (`531a07c45d0a6d30bf115155c12d002f9d3e6a6244f1c7ac5a19a67a11a488bf`).

## Physical exposure bracket on 22 November

The reference tablet booted the dev12.13 receiver from RAM with UFS and microSD disabled. The private IPA processed four consecutive matching metadata reports at each target before measuring that RAW/RGB pair. The sensor stayed pointed at the stationary scene. Light on the target and at the lens was not measured. The table shows the green-site RAW means and the processed green mean from the same central positions, with RAW black level 64.

| Sequence | Reported exposure and gain | Gr mean / 1023 | Gb mean / 1023 | Green mean / 255 | Near-black processed green |
| ---: | --- | ---: | ---: | ---: | ---: |
| 6 | 2 ms, 1× | 64.0179 | 64.0556 | 0.0000 | 100% |
| 16 | 32 ms, 1× | 64.0090 | 64.0500 | 0.0000 | 100% |
| 26 | 32 ms, 8× | 64.1571 | 64.0676 | 0.3334 | 98.21% |
| 36 | 2 ms, 1× | 64.0316 | 64.0074 | 0.0000 | 100% |

At unit gain, increasing integration sixteenfold produced no measurable increase in the mean green signal. At 8× gain, 58.63% and 61.20% of the two RAW green sites were at or below the pedestal, compared with 86.56% and 85.19% at the preceding 32 ms, 1× step. The sample distribution changed, yet every RAW site's mean stayed within 0.16 count of the pedestal. There was no sampled clipping near white. The final short exposure again yielded zero in all three processed channels. This records the response of the received pixels and libcamera's per-frame control accounting. It does not provide register readback, known illumination or proof of optical focus.

These sparse samples cover about 0.585% of the sensor. The camera app's ordinary full-resolution shutter was separately verified with a 4200×3120 rear JPEG. A repeat with the rear lens clear and a lit, textured target centred in the frame can distinguish a dark target from a continuing signal fault. [Camera shutter verification](QCAM.md)

The program completed four further automatic-mode requests, sent no AF or flash command and suspended the rear sensor after 5,859 ms of cumulative additional activity. No image was stored or transferred. The acknowledged receiver returned to daily dev12.11. Both ext4 filesystems passed a 4 KiB write, fsync and direct readback, the 1,248-package ledger matched and all four core services were active. The PC receipt `out/camera-bracket/physical-nov22/bracket.log` has SHA-256 `5f9330466b0b229944fefc69ddbe09a12ce7e9316a0451fd1d06f9e43630e2bc`. [All validated channel statistics](../tests/camera-autofocus/physical-bracket.txt)
