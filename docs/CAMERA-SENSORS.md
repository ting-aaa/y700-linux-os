# Cameras and motion sensors on TB320FC_PRC

## The three camera chips answer on Debian

The original PRC Debian kernel, `7.3.4-asphalt-prc`, recorded three successful camera silicon-ID probes and WL2864C revision `0x1` during a November 19 boot. The private Debian libcamera runtime subsequently captured full-resolution RAW and CPU-converted colour frames from each sensor.

| Position | Chip and observed ID | CCI path | CAMSS input | Mode from the board driver |
| --- | --- | --- | --- | --- |
| Main rear | HI1339 `0x1339` | `cci@ac15000/i2c-bus@0/camera@20` | CSIPHY0, four D-PHY data lanes, 608 MHz link clock | 4208×3120 GBRG10 |
| Front | S5K4H7 `0x487b` | `cci@ac15000/i2c-bus@1/camera@10` | CSIPHY2, four lanes, 340 MHz | 3264×2448 GRBG10 |
| Rear macro | SC202CS `0xeb52` | `cci@ac16000/i2c-bus@0/camera@36` | CSIPHY1, one lane, 360 MHz | 1600×1200 BGGR10 |

The product's locked DTB hash `1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d` matched the retained Linux build. That build enables `VIDEO_QCOM_CAMSS`, `VIDEO_ASPHALT_SENSORS`, `REGULATOR_WL2864C`, `I2C_QCOM_CCI`, `SM_CAMCC_8450`, the V4L2 subdevice API, UDMABUF and the system DMA heap. The Asphalt wiring patch preserves the programmed CAMSS lane mask for the macro's one-lane link. [Board wiring](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0016-asphalt-camera-wiring.patch)

The pinned same-model NixOS port reports RAW streaming, repeated start and stop, and scene photographs from all three sensors. Its software ISP uses generic tuning and a fixed lens position, with no autofocus or flash. This is the closest reuse target. Xiaomi's Diting port independently exercised the SM8450 CAMSS resources and captured S5K4H7 RAW and software-ISP output on an SM8475 device. Diting's CCI address, PHY, gain tables and power supply design differ. [Asphalt camera results](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/docs/asphalt/hardware.md#cameras) [Diting bring-up](https://github.com/royka1/diting-ubuntu/blob/main/docs/BRINGUP_STATUS.md)

### Bring up capture and desktop camera access

The Android camera service and CAMX HAL coordinate sensor power, CSI capture, the ISP and Android application access. Debian uses the board V4L2 subdevices and the CAMSS media-controller graph, then libcamera's simple pipeline and software ISP. The board's libcamera patch supplies gain and black-level helpers for all three chip names. Debian 13 ships libcamera 0.4.0 and the stock executable is a useful discovery probe. First establish the RAW graph and capture independently of desktop apps. For usable colour output, validate a libcamera backport with the three sensor helpers and the simple-pipeline fixes, and keep the PipeWire camera plugin linked against the same runtime version. [Debian libcamera](https://packages.debian.org/trixie/arm64/libcamera-tools) [Asphalt sensor helpers](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/libcamera/asphalt.patch) [Upstream software-ISP patch set](https://github.com/dianqk/nixos-android-devices/tree/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/libcamera)

The Asphalt sensor helper patch and all six shared software-ISP and link-state patches applied to `libcamera` 0.7.2-1 obtained from the authenticated Debian sid Sources index. Full sid packaging depends on Raspberry Pi components, including `libtensorflow-lite-dev`, which is absent from the tested Trixie archive. The [private backport](../scripts/build-camera-backport.sh) selects the simple pipeline, its IPA algorithms, CPU/GPU software ISP, `cam` and the GStreamer plugin. It installs in `/opt/y700-camera` and can be removed independently. [Debian sid libcamera source](https://packages.debian.org/sid/source/libcamera)

The patched source was cross-compiled against a Trixie ARM64 sysroot and the focused `debayer-geometry` test passed under QEMU. Package installation, `cam --list`, simple IPA signature verification and the GStreamer `libcamerasrc` plugin probe passed in a disposable Trixie ARM64 root without cameras. The build generates an IPA signing key for that build. Keep the private key out of the package and verify the IPA signature against the matching runtime.

On the original tablet Debian install, `cam --list` from this exact package exposed HI1339, S5K4H7 and SC202CS. The unprivileged desktop user, before an active graphical seat was available, received five full-resolution HI1339 `SGBRG10_CSI2P` RAW buffers, sequence 0 through 4 and 16,423,680 bytes per buffer. The diagnostics retained frame counts and byte lengths. Frame contents were discarded.

After the tablet returned to the original kernel, the ordinary `y700` account completed two 12-frame runs per camera, switching cameras between runs. The final RAW buffers measured 16,423,680 bytes for HI1339, 9,987,840 for S5K4H7 and 2,400,000 for SC202CS. With the CPU software ISP each sensor delivered six 640×480 ABGR8888/sRGB frames of 1,228,800 bytes. The RGB test passed both as root and as the unprivileged `lightdm` account owning the active graphical seat. That seat had write access to `/dev/udmabuf` through Debian's normal policy; the logged-out `y700` account lacked it. No permissions were changed. Each test checked strictly increasing sequences and discarded all pixels. [Capture test](../scripts/check-camera-streams.sh)

To build on Debian 13 ARM64, use the same authenticated `deb-src` configuration as the SSC build. Install `build-essential`, `dpkg-dev`, `git`, `patch`, `meson`, `ninja-build`, `pkgconf`, `openssl`, `libudev-dev`, `libyaml-dev`, `libgnutls28-dev`, `libegl-dev`, `libgles-dev`, `libdw-dev`, `libunwind-dev`, `libevent-dev`, `libjpeg-dev`, `libtiff-dev`, `libgstreamer-plugins-base1.0-dev`, `python3-jinja2`, `python3-ply` and `python3-yaml` from Trixie. The build uses the exact Asphalt checkout described below.

```sh
apt-get source --download-only libcamera=0.7.2-1
bash scripts/build-camera-backport.sh "$sources" "$asphalt" "$out"
```

1. In a Debian hardware test window, run `v4l2-ctl --list-devices` and `media-ctl -d /dev/mediaN -p` for the CAMSS graph. Match the three sensor entities and the linked CSIPHY ports. Other `/dev/video*` nodes can be codec or intermediate endpoints.
2. Run `cam --list`, select each sensor by its full ID, and capture a finite RAW stream using `cam --camera "$id" --stream role=raw --capture=30 --file='frame-#.bin'` in a private directory. To select the private runtime, use `LD_LIBRARY_PATH=/opt/y700-camera/lib LIBCAMERA_SOFTISP_MODE=cpu /opt/y700-camera/bin/cam` in place of `cam`. Record actual format, frames, sensor and CAMSS errors. Verify repeated start/stop and switching between sensors.
3. Compare frames from a controlled scene, including orientation, exposure and colour. Exercise viewfinder mode with `LIBCAMERA_SOFTISP_MODE=cpu` before combining camera workloads with GPU qualification. Verify permissions, then test access through a desktop camera application and through PipeWire. Track focus, flash and tuning separately.

The optional [Y700 Camera desktop application](QCAM.md) launches upstream qcam against the private runtime with the CPU software ISP and Qt raster viewfinder. On the physical tablet its Qt viewfinder received live frames from each sensor using the offscreen platform. An attended test covers the picture on the panel, in-app camera switching, touch controls and still capture.

Lenovo specifies autofocus on the rear main camera, fixed focus on the front and rear macro cameras, and a single rear LED. On the tested Debian installation, `cam --list-controls` returned only Contrast and Gamma for each sensor. Two independent ARM64 builds produced the kernel V4L2 flash bridge and its matching Qualcomm module. The controller remains disabled while its combined current and thermal limits are unresolved. Main-camera autofocus and rear flash still need hardware integration. [Focus and flash driver work](CAMERA-FOCUS-FLASH.md) · [Lenovo TB320FC specifications](https://psref.lenovo.com/Product/Lenovo_Tablets/Legion_Tab) · [Asphalt camera implementation](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/docs/asphalt/hardware.md#cameras)

## SSC on Debian

The same boot reported SLPI remoteproc present and `-2` (`ENOENT`) for `qcom/sm8475/lenovo/tb320fc/slpi.mdt`. The retained kernel includes Qualcomm PAS, FastRPC and the in-kernel PD mapper as modules. The driver path is SLPI remoteproc → `fastrpc-sdsp` → the native FastRPC `sdsprpcd sensorspd` listener, with QRTR/QMI to libssc and iio-sensor-proxy. Android's framework obtains readings from vendor services and the sensor HAL. The native Xfce session consumes the standard `net.hadess.SensorProxy` system D-Bus interface. [Session implementation](../src/sensors/rotation_session.py)

### Xfce screen rotation

Open **Settings → Tablet rotation** to enable automatic rotation or to hold the current orientation. Each user's setting persists across logins. The default is locked. The Xfce autostart in platform dev7 watches for a sensor provider when the desktop starts. An active, unlocked seat and an enabled preference are required to claim the accelerometer. If the sensor is unavailable the current display orientation is preserved. The setting can also be read with `gsettings get org.y700.tablet auto-rotate`.

The Asphalt libssc and proxy patches already convert the device coordinates. The desktop maps `normal`, `left-up`, `bottom-up` and `right-up` to RandR `normal`, `left`, `inverted` and `right` respectively. A cardinal pose must persist for 0.8 seconds. Laying the device flat, losing the provider or locking the session cancels a pending rotation. The existing display helper maps the NT36523N touchscreen to DSI-1 and attempts to restore the previous rotation if touch mapping fails. [Asphalt mappings](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/mobile/sensor-rotate/rotate.py) · [RandR rotations](https://manpages.debian.org/trixie/x11-xserver-utils/xrandr.1.en.html#rotate)

SensorProxy 3.9 sends signals specifically to clients that claim the sensor. It can hold the first claim reply until a sample arrives. The session receives signals on its own bus connection, checks live properties before applying a rotation and renews its claim while enabled to recover from silent driver resets. The settings window reads availability without claiming the sensor. [D-Bus contract](https://hadess.pages.freedesktop.org/iio-sensor-proxy/gdbus-net.hadess.SensorProxy.html) · [Upstream implementation](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/blob/3.9/src/iio-sensor-proxy.c)

The packaged client passed 11 lifecycle checks on Linux x86-64 and in Debian 13 ARM64 userspace under QEMU. Both runs used real GLib, dconf and two private buses with simulated logind, sensor and display endpoints. The ARM64 GTK test used Xvfb at 100% and 200% scale and checked a pointer click and preference persistence across sessions. The physical baseline still needs SLPI readings, four-way panel rotation and finger alignment. The command-line bridge defaults to observing `monitor-sensor --accel` for that comparison. [Session test](../tests/rotation-session.sh) · [Touch-size settings test](../tests/tablet-rotation-x11.sh)

Use SLPI metadata and every referenced segment from one firmware build. The existing [CN350 comparison](research/cn350-firmware-comparison.json) shows different SLPI metadata and segment bytes from the NixOS ZUI 17.0.339 bundle. Selected Hexagon SDSP listeners and skeletons matched across both. Preserve the existing calibration state on subsequent starts. The generation script supplies generic defaults for MTP, SoC 531 and registry version 7. Candidate IMU entries in those defaults do not identify the fitted device. [Hardware map and firmware comparison](HARDWARE-MAP.md#sensor-migration-finding) [Asphalt service](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/modules/mobile/ssc-sensors.nix)

### Native userspace backport

The `libssc` 0.4.4-2.1 and `iio-sensor-proxy` 3.9-1 sources are available through Debian's signed sid Sources index. Trixie's `iio-sensor-proxy` 3.7-3 lacks the required SSC backend. The ARM64 Debian 3.9 packaging explicitly enables SSC. Rebuild both from source on Trixie rather than importing sid runtime libraries. The two coordinate fixes at the Asphalt pin preserve native device-frame samples at the library boundary and map the two in-plane axes once in the proxy. Debian source hashes and the Qualcomm FastRPC source hash are enforced by the [build script](../scripts/build-ssc-backport.sh). [Debian libssc source](https://tracker.debian.org/pkg/libssc) [Debian iio-sensor-proxy source](https://packages.debian.org/sid/source/iio-sensor-proxy) [FastRPC daemon documentation](https://github.com/qualcomm/fastrpc/blob/v1.0.7/Docs/daemons.md)

Build in a disposable Debian Trixie ARM64 root. Fetch the pinned source archives and obtain the exact clean Asphalt checkout using `scripts/fetch-upstream.sh`. Add only `deb-src https://deb.debian.org/debian sid main` to a build-host source list served by the Debian archive keyring. Inside a fresh source directory use the authenticated source index to download, then fetch FastRPC by tag. The GitHub tag points to `228d98b5f143ed917789cde017a8aa548e65b80b`. The archive's unpacked NAR hash matches the Asphalt FastRPC recipe.

```sh
apt-get source --download-only libssc=0.4.4-2.1 iio-sensor-proxy=3.9-1
curl -fL https://codeload.github.com/qualcomm/fastrpc/tar.gz/refs/tags/v1.0.7 \
  -o fastrpc-v1.0.7.tar.gz
```

Install build dependencies from Trixie. The two Debian `.dsc` files list their package dependencies. Install `build-essential`, `dpkg-dev`, `patch` and `git`, and for FastRPC install `autoconf`, `automake`, `libtool`, `pkgconf`, `libyaml-dev` and `libbsd-dev`. Run the build script against the private source directory, exact Asphalt checkout and an output directory. Install the resulting `libssc-dev`, `libssc2` and `gir1.2-ssc-2` packages only in the build root before compiling the proxy. The listener archive is a build output for a later package. It carries only the SDSP daemon, shared libraries and license. [Asphalt FastRPC recipe](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/mobile/fastrpc/default.nix)

```sh
bash scripts/build-ssc-backport.sh libssc "$sources" "$asphalt" "$out"
# Install the just-built library and headers in the disposable build root.
bash scripts/build-ssc-backport.sh proxy "$sources" "$asphalt" "$out"
bash scripts/build-ssc-backport.sh fastrpc "$sources" "$asphalt" "$out"
```

In a disposable Trixie ARM64 root under QEMU, the build produced `libssc` `0.4.4-2.1~bpo13+1.y7001`, `iio-sensor-proxy` `3.9-1~bpo13+1.y7001` and the patched FastRPC 1.0.7 SDSP archive. The upstream targeted regressions exercised libssc placement decoding, proxy mapping of four directions and face tilt, and the FastRPC listener frame checks. Both Debian runtime packages installed in the build root, and `ssccli --help`, `monitor-sensor --help` and the proxy's `libssc.so.2` linkage were checked. The FastRPC archive contains AArch64 ELF objects and resolves runtime dependencies through `libbsd0`, `libyaml-0-2`, `libsystemd0` and glibc. These checks cover build and execution without a DSP. The full libssc mock suite requires kernel QRTR support and was skipped here.

### Private firmware and opt-in service

[`build-ssc-firmware.py`](../scripts/build-ssc-firmware.py) builds `y700-ssc-cn350-firmware` locally from the two verified CN350 OTA partition images. It checks both complete image hashes, compares the FAT inventory against the recorded manifest, checks the 26 SLPI and seven SDSP payloads individually, and verifies the lengths of all 21 file-backed Hexagon MDT load segments. The runtime needs the original coherent image set, including its metadata. Segment 22 has no file data. The packager never writes to the input images. It generates defaults through the pinned `MTP` / SoC `531` / version `7` registry recipe. The archive includes 329 registry groups, and two independent builds matched byte for byte. Keep this archive private. [CN350 comparison](research/cn350-firmware-comparison.json) [Asphalt registry and firmware recipe](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/sensors/default.nix)

[`build-ssc-runtime.sh`](../scripts/build-ssc-runtime.sh) packages the SDSP listener from the checksum-identified FastRPC build and rejects libraries with temporary build search paths. It installs an opt-in systemd service and has no install-time service activation. The package's scoped udev rule adds SSC acceleration and proximity on the `fastrpc-sdsp` node. Debian's proxy rule supplies light and compass support. The service maps its board config and DSP libraries to the vendor paths inside its own mount namespace. Both legacy persist paths resolve to `/var/lib/y700-ssc`, with first-start seeding protected against concurrent starts. Subsequent starts preserve every byte of the existing registry and calibration. The proxy waits for a real accelerometer sample with bounded retries. [Upstream service model](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/modules/mobile/ssc-sensors.nix)

On a Linux build host with `mtools`, `e2fsprogs`, Debian packaging tools and uv, build the private archives as follows. Use the SHA-256 printed by the exact native FastRPC archive build.

```sh
uv run --python 3.13 --no-project python scripts/build-ssc-firmware.py \
  "$cn350_stock" "$asphalt" "$private_out"
bash scripts/build-ssc-runtime.sh "$verified_fastrpc_tar" "$fastrpc_sha256" "$private_out"
bash tests/ssc-runtime.sh
```

The seed and readiness tests passed concurrent initialization, preservation of changed calibration, symbolic-link rejection and sample-gated startup. The FastRPC archive and runtime package each matched a second build byte for byte. The firmware and runtime installed offline in an isolated Trixie ARM64 root with the matching proxy and library. Dpkg audit, APT dependency checks, systemd 257 unit checks, udev rules validation and private library resolution passed. No calibration directory was created during installation. SSC waits for hardware and an explicit listener start.

To include the private CN350 firmware and native SSC stack in an offline development image, run `bash scripts/add-board-layer.sh ssc "$root" "$ssc_archives"` against the disposable ARM64 build root. It verifies all eleven archives and records the exact package set for the image builder. The FastRPC listener is disabled. The kernel can load the firmware on its next probe. Image assembly excludes per-device registry and calibration data. The [SSC layer lock](../config/ssc.lock.json) identifies six Debian dependency archives and five local builds.

### Physical SSC qualification

The [initial SLPI trial tool and procedure](SSC-TRIAL.md) cover the read-only preflight, one bounded activation with a pre-armed listener, and PID 1 cleanup. On this unit the passive tool verified the actual PRC board, calibrated state, CN350 archive and live carveout.

On the November 19 tablet boot, the running kernel requested `qcom/sm8475/lenovo/tb320fc/slpi.mdt` and received `ENOENT`. The SLPI was offline, ADSP was running and only the ADSP FastRPC character device existed. The CN350 split firmware fits the 25 MiB reserved SLPI region, and the in-kernel protection-domain mapper was bound. The eleven-package SSC stack was installed on the tablet with the split SLPI payload excluded from the permanent firmware path for this initial trial. The complete firmware was staged in volatile storage. The 0.1.1 seed helper ran twice under the service's actual systemd mount restrictions. It imported 124 calibration groups from this unit's internal UFS, yielding 375 groups, then retained all bytes on the second run. The six native collectors and the Hall discovery probe returned `SSC QMI Service not found`. First activation and physical readings remain open. [Per-device import](SSC-CALIBRATION.md) · [Hall probe](SSC-HALL.md)

1. On the known `TB320FC_PRC` Debian boot, record the current SLPI state, requested path, kernel version and package versions. Keep the original USB route available. Install the reviewed private firmware and runtime packages, matching patched `libssc2`, `libssc-bin`, `iio-sensor-proxy` and the signed Debian dependency closure. There is no automatic listener start by the new packages. The firmware becomes available to the kernel on a subsequent reboot.
2. Check the in-kernel `qcom_pd_mapper`, the remoteproc named exactly `slpi` and its requested path. For a first trial, arrange the sensor-domain listener to launch when the SDSP device appears and record a kernel journal cursor before requesting one start from the offline state. Starting the DSP alone can leave firmware waiting for its listener. The tablet exposed no hardware watchdog on this boot. An AP hang may require the physical power button. Record the first PAS, GLINK or protection-domain fault. A healthy transport has a running SLPI and `/dev/fastrpc-sdsp` with SSC udev properties.
3. Verify the listener, QRTR discovery and the desktop proxy's readiness. Collect finite reports for accelerometer, gyroscope, magnetometer, light, proximity and compass. Record accepted sample counts, timestamps and close status. Discovery, an acknowledged subscription with zero measurements, and an actual sample represent different results. Discover and exercise the separate on-change Hall stream with a cover. [Finite collector](../tests/ssc-sample.md) · [Hall discovery and testing](SSC-HALL.md)
4. Confirm four physical screen directions via `monitor-sensor --accel` and the X11 bridge in observe mode. Check touch alignment before enabling rotation. Check the actual Hall sensor route and suspend/resume independently. For rollback, stop the proxy and listener, return SLPI to its original state if the experiment started it, and uninstall the local packages as appropriate. Preserve `/var/lib/y700-ssc` when retrying. The pinned same-board NixOS instructions configure this path and leave physical motion readings and resume pending. [SSC reference](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/docs/sensors.md)

This unit's hash-verified Android `persist` backup lists accelerometer, gyroscope, magnetometer, ambient light, proximity and Hall data types. Its registry contains all 329 groups in the pinned generic seed and 49 additional records, including 44 gyro calibration or temperature records and two magnetometer calibration records. Compared with the seed, factory-calibration fields differ for BMI3x0 acceleration and gyro, STK3A5x ambient light and proximity, and both MMC56x3x and QMC630x magnetometer families. The Hall groups match the generic seed. These results narrow the families to check during live qualification. Fitted chip models, the Hall interface and Debian sensor readings still require a live test.

### Desktop service regression

An isolated ARM64 guest boots the Y700 kernel with the board root mounted read-only and a tmpfs overlay. A QEMU-only misc device supplies the SDSP name matched by the packaged udev rules. Upstream libssc 0.4.4's mock supplies sensor traffic over actual Linux QRTR. Debian's udev, libssc, iio-sensor-proxy and system D-Bus process the events. A single client claims and releases three sensors. The regression requires at least two screen orientations, two finite light levels and both proximity states. The fixture exercises the desktop API through the kernel transport. The tablet's DSP firmware, calibration accuracy and physical axes need on-device qualification. [Guest, client and host runner](../tests/ssc-desktop/)

Run as root on a Linux build host with QEMU, cpio, an ARM64 Clang kernel build tree and ARM64 binfmt enabled. Supply the raw board ext4 root, the matching kernel build, the locked upstream libssc 0.4.4 archive, a build sysroot with `protoc`, Python protobuf and libqrtr, and ARM64 BusyBox (static) and uv executables.

```sh
bash tests/ssc-desktop/run.sh "$root_ext4" "$kernel_build" "$libssc_tar" \
  "$arm64_build_root" "$static_arm64_busybox" "$arm64_uv"
```
