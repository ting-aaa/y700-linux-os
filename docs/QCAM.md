# Optional Y700 Camera desktop application

`y700-camera-qcam` packages the upstream libcamera 0.7.2 Qt camera viewer for Debian 13 ARM64. Xfce shows **Y700 Camera** under Graphics. The launcher uses the existing `y700-camera-runtime` in `/opt/y700-camera`, selects the CPU software ISP and opens the X11 Qt raster viewfinder with Xcb GL integration disabled. Upstream qcam includes camera selection, start and stop, and still-image save controls. [qcam source](https://git.libcamera.org/libcamera/libcamera.git/tree/src/apps/qcam?h=v0.7.2)

## Build and install

Use the same authenticated libcamera source archives and pinned Asphalt checkout as the [camera runtime build](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access). Add Trixie's `qt6-base-dev` and `libqt6opengl6-dev` to the build environment. The upstream binary links the Qt OpenGL frontend even when launched with the raster renderer. The qcam build produces only the optional desktop package and depends on the exact existing camera runtime version.

```sh
bash scripts/build-camera-backport.sh --qcam "$sources" "$asphalt" "$out"
sudo apt-get --no-install-recommends install "$out"/y700-camera-qcam_0.7.2-1~bpo13+1.y7001_arm64.deb
```

On the verified 1050-package ARM64 image, APT selected 17 additional Debian packages with zero upgrades or removals. The app archive was about 106 KB. The full addition was 8.43 MB in archives and 33.6 MB installed. The optional [Debian archive lock](../config/camera-qcam-debian-auth.lock.json) matches those 17 packages against signed Trixie metadata. The lock describes the snapshot used for this test.

On an offline disposable copy of that image, fetch the locked archives on a connected build host and copy them with the app archive into the installation environment. Install them together. `sudo apt-get purge y700-camera-qcam` removes the application and leaves the camera runtime installed.

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
  --lock config/camera-qcam-debian-auth.lock.json --cache "$qcam_deps"
sudo dpkg -i "$qcam_deps"/*.deb "$out"/y700-camera-qcam_0.7.2-1~bpo13+1.y7001_arm64.deb
sudo apt-get check
```

## Verification

The package installed offline in a disposable overlay of the 1050-package image. In a camera-free ARM64 Xvfb session the `y700` user opened the installed desktop entry. The chooser appeared and closed in response to Cancel. The process mapped the private libcamera and Qt's Xcb platform plugin without loading an Xcb GL integration plugin. Package removal preserved the existing `cam --list` entry point. Run the fixture with `xvfb` and `xdotool` installed in the disposable environment. [X11 fixture](../tests/camera-qcam-x11.sh)

The final app archive has SHA-256 `a89c0b4bc3793c36359c45cf7c0840ea03e9de219128715785c73bff113444b0`. On the tablet it installed alongside 17 new dependencies. The package audit, APT dependency check and original LightDM invocation passed after installation. The app remains a separate install for the combined image.

In an unattended hardware run, the current greeter seat's unprivileged account started the installed launcher with Qt's offscreen platform and the CPU ISP. Seven-second runs received 95 main, 202 front and 202 macro viewfinder frames, each 640×480 ABGR8888. The test checked buffer lengths and sequence order and closed each app cleanly. It saved no photographs. The visible camera picker and preview on the internal panel, touch operation, still-image quality and switching within a single session need an attended test. [Hardware viewfinder fixture](../tests/qcam-tablet-preview.sh)
