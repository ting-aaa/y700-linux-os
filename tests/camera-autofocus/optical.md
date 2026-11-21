# Rear autofocus measurement

On the PRC tablet the [board runner](../camera-lens-graph/measure-board.sh) uses a transient ordinary-user service with a private network and a 70-second limit. Pass `--self-test` to run synthetic cases with camera devices hidden. The separately selected `--rear-af` mode measures a real scene; use it for a consented, attended trial with a suitable target. In both modes the runner checks that the rear sensor has returned to runtime suspend before exiting.

For a USB session, stage the runner as `measure-board.sh` and the executable in a new root-owned `mktemp -d /run/y700-af-optical.XXXXXXXX` on tmpfs. Give the directory and executable ordinary-user traversal and execution permissions. Invoke the staged runner with `--detached-rear-af EXECUTABLE`. It returns the transient service name and a private `receipt.log` path. After the service exits, read the receipt and look for both the terminal result and `AF_CLEANUP`. The log survives a USB disconnect within that boot. A reboot discards it. Both real-camera modes check root mount flags and hold a sleep inhibitor while the measurement runs.

Use a stationary, well-lit, textured target with visible fine edges near the centre of the preview. Keep the tablet and target still throughout the measurement. Each invocation of `--rear-af` opens the rear HI1339 for one 640×480 ABGR8888 viewfinder stream using the packaged CPU ISP. The sole actuator command is the normal libcamera `AfModeAuto` and `AfTriggerStart` pair in one request. The program neither creates a window nor encodes or saves images. The ordinary account running the measurement needs the same camera and dma-buf access as qcam.

For the y7002 runtime, place the checked diagnostic `libcamera.so.0.7` beside the staged executable and set `Y700_AF_DIAGNOSTICS=1` on the board runner. It verifies the candidate and both installed camera libraries. Only this transient process then uses the diagnostic library. Its `AF_DIAG` line identifies the terminal scan phase and reason and counts accepted lens controls and samples. A successful control call only shows that the driver accepted the command. [Diagnostic source change](../../packaging/camera-autofocus/scan-result-diagnostics.patch)

```sh
export LD_LIBRARY_PATH=/opt/y700-camera/lib
export LIBCAMERA_LOG_LEVELS='*:FATAL'
./y700-af-measure --self-test
timeout -k 3s 70s ./y700-af-measure --rear-af
```

`--self-test` exercises padded RGB planes, textured and uniform targets, changing light, framing changes, an unstable preview and terminal AF states in memory. It exits before starting a CameraManager. The last line is `AF_RESULT self_test=pass synthetic=1 camera_access=0`. The existing [stream test](stream.cpp) separately runs the production search against a GStreamer stream with simulated lens blur. Run it through [run.sh](run.sh) on an ARM64 build system.

The physical measurement discards 24 warmup frames. It compares consecutive, non-overlapping groups of eight idle frames. Both groups must have stable sharpness and lighting. The applied exposure time and analogue gain must each stay within 2% across all 16 frames. The runner withholds the trigger if this baseline is missing by frame 664. After scanning reaches a terminal AF state it discards three settling frames and measures eight more. It accepts at most 944 returned requests within a 60-second monotonic capture deadline. The outer timeout also bounds enumeration, start and stop. Accepted timestamps must increase. A busy rear camera, missing controls, bad buffers, interrupted sequence or timeout produces `AF_ERROR` and a nonzero exit.

| Output | Interpretation |
| --- | --- |
| `AF_PREVIEW` | Stability and median sharpness of the idle preview before the single trigger. |
| `AF_SCAN` | Number of frames with scanning metadata and the terminal state reported by the product runtime. An immediate failure can report zero scanning frames. |
| `AF_RESULT verdict=improved` | On a stationary target, the median post-focus sharpness exceeds the idle median by more than 15%, an absolute 0.006 and twice either window's spread. Both windows passed the signal and stability guards. |
| `sharpness_decreased` | The camera reported Focused, both windows passed the guards, and the median sharpness fell by more than the same threshold used for improvement. |
| `no_gain` | The camera reported Focused and the scene passed the guards. The absolute change in median sharpness was at or below the threshold. An initially focused target can give this result. |
| `inconclusive` | The camera reported Focused, but texture, focus-score stability, clipping, illumination or scene consistency limited interpretation. |
| `af_failed` | The camera reported Failed. |

The independent sharpness metric averages the absolute four-neighbour green-channel Laplacian in the central half of the viewfinder, normalized by mean brightness. Eight-frame windows use the median score and the full score spread. Sixteen coarse, brightness-normalized tile means provide an in-memory framing guard. Output contains their aggregate distance only. The AF engine itself samples two-axis first differences. The independent measurement still responds to motion, noise, contrast and scene changes that escape the coarse guards. Its result describes that target at that distance and does not measure lens travel, absolute resolution or accuracy across distances.

## Check viewfinder configuration without starting a stream

Run `y700-af-measure --check-rear-config` as the intended camera user. It acquires the rear HI1339, requests 640×480 ABGR8888, validates it, calls `Camera::configure()` if the exact format and size survived, then releases the camera. Both this mode and `--rear-af` print the generated, requested and validated geometry, format and FourCC. The validated stride reflects the negotiated format. `called=0 rc=none` means the probe stopped before configuration. `called=1` reports libcamera's actual return value and its corresponding errno number. A passing configuration-only run allocates zero application frame buffers, starts zero streams, queues zero requests and reads zero pixels.

`AF_CONFIG_RESOURCE` reports which of the four allocator nodes the process can open read/write. The check closes each descriptor without issuing an allocation ioctl. It also checks the installed soft IPA module, signature, worker and tuning paths. The generic tuning file is supported when `hi1339.yaml` is absent. Module readability alone does not verify an IPA signature or prove that the IPA loaded. [Probe source](optical.cpp) · [Resource checks](optical-config-resources.h)

On the PRC tablet the unlogged-in account's ordinary transient service received `EACCES` on all three present allocator nodes. Validation changed the requested preview to the sensor's 4208×3120 packed Bayer format and the probe released the camera before configuration. On the same tablet a private systemd bind mount made just `/dev/udmabuf` accessible to the service. The requested 640×480 ABGR8888 validated with stride 2560, configuration and release both returned zero, and the sensor remained suspended with zero additional runtime-active milliseconds. This comparison identifies allocator access as the reason for the format change in that service. Optical focus requires a separate streamed measurement. The physical receipt `out/camera-optical-qa/physical-private-config-v2.log` has SHA-256 `64a8794976f7b60847b0ce0b051fe13e230361a4aa29d993f79ece359e607d20`.

The tested configuration probe has SHA-256 `f2f0536739cca7de9eb620f8b2677b8d37b44d55bd6f8f8982f1e202ff784900`. On a PC, the unmodified Debian 0.7.2 virtual camera accepted acquisition and adjusted the requested format to NV12. Both probe modes reported the adjustment, skipped configuration and released the camera. Run this test on a host with ARM64 execution support, a prepared ARM64 root directory and the archives from the existing [virtual runtime lock](../qcam-photo/virtual-runtime.sha256). [Test runner](check-virtual-config.sh)

```sh
sudo bash tests/camera-autofocus/check-virtual-config.sh "$arm64_root_dir" "$virtual_runtime_debs" "$measure"
```

A separate test-only virtual pipeline advertises ABGR8888 for configuration and disables buffer export and streaming for that format. The exact same ARM64 probe reached configuration and release successfully. When the virtual pipeline injected `-ENOSPC` into its configure operation, the probe reported `called=1 rc=-28 errno=28`, released the camera and exited with status 1. The four-run PC receipt is `out/camera-optical-config/virtual-config-matrix.log`, SHA-256 `d2369c9c4c78b200081e4d6ee6ea5b2008ed26d2f97916cbc8483bf0875ddfe2`. To reproduce, first build the fixture library in an ARM64 development environment. [Virtual test pipeline](virtual-config-only.patch)

```sh
bash tests/qcam-photo/build-virtual-runtime.sh "$libcamera_0_7_2_source_tar" "$config_test_libs" --rear-config-only
sudo bash tests/camera-autofocus/check-virtual-config.sh "$arm64_root_dir" "$virtual_runtime_debs" "$measure" "$config_test_libs"
```

## Build and reproduce the measurement tool

The estimator checks the guards before comparing the two scores. A post-focus median below 0.012 yields `inconclusive` even after a large drop. The synthetic self-test includes a sharp-to-soft textured chart, a transient change in framing during scanning, and decreases equal to and greater than twice either window’s spread.

In the ARM64 self-test, the sharp-to-soft chart measured 0.3624 before the trigger and 0.1130 after it. The estimator reported `sharpness_decreased`. With the same endpoints and five scanning frames showing a framing change, it reported `inconclusive`. The tested executable has SHA-256 `2bf6eec0bbe5a0c306757d6b21ad5693110c2272aa94969ad31d7aea6a59a3dd`.

Build against the y7002 runtime and libcamera 0.7.2 public headers on an ARM64 development root. The two include directories below correspond to the source and configured Meson build trees. The script runs the synthetic test before it publishes the executable.

```sh
bash tests/camera-autofocus/build-optical.sh \
  /build/camera-source/include /build/camera-build/include ./y700-af-measure
```

The client reuses completed request buffers and brackets each CPU read with dma-buf cache synchronization. [libcamera request API](https://docs.libcamera.org/master/public-api/classlibcamera_1_1Request.html) · [Linux dma-buf userspace access](https://docs.kernel.org/driver-api/dma-buf.html)

The sealed RAM trial uses the earlier measurement executable, SHA-256 `472008d206303c671233deb556570a5e2a8760959d53349dd8e028930372eecc`. Its `no_gain` includes decreases that meet the quality guards. Use the printed `before` and `after` values when reading those receipts. To rebuild the sealed executable, export its original sources with the following command and run the build command above from the extracted directory in the original ARM64 development root. Build the newer estimator to a separate output path. [Sealed attachment input checks](../ram-af-acm/build.sh)

```sh
git archive 66216fa4a4cde7b0c2cdd666ba3c15a6cb5f1ff5 tests/camera-autofocus | tar -x -C "$legacy_source_dir"
```

The intermediate sharpness-estimator executable `2bf6eec0…` can be rebuilt with the same command using commit `51a794f0baf18d8926f4e2a726ad70291a3ec808`.
