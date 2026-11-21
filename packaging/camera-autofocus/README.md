# Single-shot focus on the Y700 rear camera

The optional `y700-camera-runtime` version `0.7.2-1~bpo13+1.y7002` adds contrast autofocus to the private libcamera simple pipeline in `/opt/y700-camera`. Applications use the standard libcamera controls. [libcamera 0.7.2 control definitions](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/libcamera/control_ids_core.yaml)

The camera must match the board's rear `hi1339` sensor ID, its associated `gt9768` lens and a valid `V4L2_CID_FOCUS_ABSOLUTE` interval supplied by the driver. The processed stream must provide packed RGB/BGR pixels with three or four bytes per pixel through SoftISP. The previous camera graph, front and macro cameras, and a raw-only configuration retain their existing controls. The driver returns each unit's calibrated DAC interval. Optical dioptres are unknown.

An application can put `AfModeAuto` and `AfTriggerStart` in the same request. Ordinary preview starts in `AfModeManual`. During a scan the runtime reads gradients from the central half of the processed image, sweeps the calibrated range, refines around the strongest position and checks that position again. Each move waits at least 50 ms and skips the first completed exposure after settling. Two distinct later frames provide each score. The cap is 19 moves. With a continuing stream the scan fails after 45 seconds.

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
