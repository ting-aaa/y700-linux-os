# Single-shot focus on the Y700 rear camera

The optional `y700-camera-runtime` version `0.7.2-1~bpo13+1.y7002` adds contrast autofocus to the private libcamera simple pipeline in `/opt/y700-camera`. Applications use the standard libcamera controls. [libcamera 0.7.2 control definitions](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/control_ids_core.yaml)

The camera must match the board's rear `hi1339` sensor ID, its associated `gt9768` lens and a valid `V4L2_CID_FOCUS_ABSOLUTE` interval supplied by the driver. The processed stream must provide packed RGB/BGR pixels with three or four bytes per pixel through SoftISP. The previous camera graph, front and macro cameras, and a raw-only configuration retain their existing controls. The driver returns each unit's calibrated DAC interval. Optical dioptres are unknown.

An application can put `AfModeAuto` and `AfTriggerStart` in the same request. Ordinary preview starts in `AfModeManual`. During a scan the runtime reads gradients from the central half of the processed image, sweeps the calibrated range, refines around the strongest position and checks that position again. The released y7002 runtime starts its 50 ms timer before issuing each synchronous lens command. It skips the first eligible completion and uses two distinct later frames for each score. The cap is 19 moves. With a continuing stream the scan fails after 45 seconds.

`AfState` in completed request metadata reports Idle, Scanning, Focused or Failed. Explicit Cancel and a switch back to Manual stop an active scan. A capture error or delivered bad ISP frame terminates the scan as Failed, including when that frame carries Start. A later valid frame repeats that result. A flat scene, an invalid measurement and an actuator error also fail the scan. Stopping the camera resets the state and closes its actuator handle. Enumeration closes the query handle after reading the range, so an idle camera manager can coexist with a second process that focuses and then releases the lens.

## Build and install

On the same ARM64 Debian build system used for the existing camera packages, pass the pinned Debian source archive directory and Asphalt checkout to the normal builder. It applies the existing board patches before the autofocus extension. The original runtime build still uses the command without an option. libcamera creates a fresh IPA signing key for a runtime build. For exact deployment, verify the three archives against the retained build manifest.

```sh
bash scripts/build-camera-backport.sh --autofocus "$sources" "$asphalt" "$out"
bash scripts/build-camera-backport.sh --qcam-autofocus "$sources" "$asphalt" "$out"
bash scripts/build-camera-af-pipewire.sh "$stock_spa" "$stock_runtime" \
    "$out/y700-camera-runtime_0.7.2-1~bpo13+1.y7002_arm64.deb" "$out"
```

Upgrade the three camera packages together on a matching desktop. The unchanged SPA backend checks all 51 imports from the two private libraries and retains the exact compressed package data member, including its WirePlumber configuration. The updated SPA package and qcam each accept either runtime. The previous qcam and SPA packages require the original runtime. For rollback, install all three original archives in one local transaction.

## Verification

`tests/camera-autofocus/run.sh` links an ARM64 executable to the packaged private library. It obtains real, padded RGB frames from GStreamer's test source and applies simulated optical blur before feeding pixels to the production measurement code. Across two synthetic calibrated ranges, the returned positions were 484 for a known optimum of 487 and 625 for an optimum of 622. Each result used 19 moves and 38 measured frames. The same executable tests a featureless scene, late frames, cancellation, lost or faulty trigger frames, lens-range checks, a rejected move and stop/restart. These measurements cover algorithm behavior on controlled images. Focus accuracy and settling on a real scene require a hardware test.

The same frozen runtime and executable also passed on the physical tablet's CPU under `/run`, with private devices and network, using only GStreamer's core elements, test source and app sink. The two synthetic results matched the PC run. The tablet's boot and installed package inventory were preserved. The receipt is `out/camera-qcam-y7005/tablet-af-stream.log`.

```sh
bash tests/camera-autofocus/run.sh
sudo bash tests/camera-autofocus/packages.sh "$wifi_staged_root" "$original_three_debs" "$updated_three_debs"
```

The second command uses a read-only generic dev12.10 image with the two Wi-Fi updates and a disposable overlay. It checks APT, dpkg and ELF relocations for qcam, cam, GStreamer and the SPA plugin before and after upgrading, then restores all 1,240 original package tuples. The frozen archives and run receipts live under `out/camera-autofocus/`. Check the distributed archives and test executable against the [qualified release hashes](../../tests/camera-autofocus/release.sha256).

### Candidate for delayed lens commands

The candidate records a second monotonic timestamp immediately after a successful lens control returns. A completion must be at least 50 ms later than that timestamp. The first eligible completion is still discarded because its exposure can overlap that interval. The Y700 CAMSS VFE records `ktime_get_ns()`, the V4L2 queue specifies monotonic timestamps, and the CPU ISP copies the input timestamp to its output. The ARM64 Debian implementation of `steady_clock::now()` calls `clock_gettime(CLOCK_MONOTONIC)`. [Candidate source](settle-after-control.patch) · [Timing regression](../../tests/camera-autofocus/settling.cpp)

Use a separate prepared y7002 source tree with the diagnostic patch applied. From the product repository, build and run the regression on that tree.

```sh
patch --fuzz=0 -d "$candidate_source" -p1 < packaging/camera-autofocus/settle-after-control.patch
pipeline="$candidate_source/src/libcamera/pipeline/simple"
c++ -std=c++17 -O2 -I"$pipeline" tests/camera-autofocus/settling.cpp \
  "$pipeline/contrast_scan.cpp" -o "$candidate_source/settling-test"
"$candidate_source/settling-test"
```

With an injected 120 ms control delay the previous build scored a frame timestamped 90 ms. The candidate rejected it, discarded the first eligible completion at 170 ms and its duplicate, then scored the frames at 190 and 220 ms. The ARM64 candidate library also loaded the two signed IPAs and passed the packaged GStreamer scan tests on a PC. Its SHA-256 is `ab1cd0e90330a2b3905d8103b5be42fa098c4f15e494e8284c13f4decfcc5d23`. The experimental library and receipts are in `out/camera-af-settling/`. The sealed RAM trial uses the previous diagnostic library. The physical trials did not measure the elapsed duration of their lens commands.

### Comparing both focus metrics on the same frames

After the settling candidate, [score-pairs.patch](score-pairs.patch) adds one opt-in `Y700Af:DEBUG` row per completed pair, up to 19 per scan. Its one-based ordinal is local to coarse, fine or verify. Four integer fields give the mean and absolute difference of the two normalized gradient scores, in millionths, first on the production grid and then on every central pixel with a right and lower neighbour. Both grids use the same two mapped frames. Missing reference samples suppress that row. At 640×480 the reference reads 76,241 sites per accepted frame. Larger frames skip the reference. The scan still uses the original score, 0.025 floor, 1.12 peak-to-trough ratio and verification rule.

A deterministic synthetic target with equal mean brightness exposed a sampling blind spot. In one of three horizontal phases, nine coarse measurements all scored 0.033900 while the dense reference ranged from 0.033966 to 0.137323. Shifting the detail one pixel horizontally allowed the same code to focus. The independent [full-grid VGA decision candidate](full-grid-vga.patch), applied to the settled source on its own, focused at all three phases and still rejected a fixed noisy target. No measured score establishes this mechanism on the physical tablet. In its 419-frame run, coarse scan accepted nine lens calls and 18 scores, rejected 18 timestamps and returned `flat-contrast`. Its 0.0573 and 0.0642 values came from the separate Laplacian observer.

To repeat the build on a Linux host with ARM64 binfmt support, supply the Debian ARM64 SDK and the prepared object/source tree used for the settled diagnostic. The [rebuild script](../../tests/camera-autofocus/build-score-pairs.sh) first reproduces its exact ELF, then builds the paired library and exercises the three versions on ARM64. It writes into a new output directory.

```sh
sudo bash tests/camera-autofocus/build-score-pairs.sh "$sdk" "$settled_build" "$new_output"
```

Two builds produced SHA-256 `a56b92c1c2528582e23b151275291d4cbb4ae70e7fc8c446c885914f5c715012`. Existing GStreamer, ABI and signed IPA checks passed. The ten synthetic protocol lines and two timing measurements are in `out/camera-af-score-pairs/rebuilt/paired.log`. Timings there are host ARM64 emulation measurements.