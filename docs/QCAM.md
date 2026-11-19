# Optional Y700 Camera desktop application

`y700-camera-qcam` packages the upstream libcamera 0.7.2 Qt camera viewer for Debian 13 ARM64. Xfce shows **Y700 Camera** under Graphics. The launcher uses the existing `y700-camera-runtime` in `/opt/y700-camera`, selects the CPU software ISP and opens the X11 Qt raster viewfinder with Xcb GL integration disabled. Upstream qcam includes camera selection, start and stop, and still-image save controls. [qcam source](https://git.libcamera.org/libcamera/libcamera.git/tree/src/apps/qcam?h=v0.7.2)

On Xfce X11, revision `y7002` gives qcam a 2× scale when the sole active output is the native Y700 panel, Xfce requests 200%, and X11 actually publishes the standard 96 Xft DPI. The launcher's fallback respects custom Xft DPI and explicit Qt scale, DPI or platform-theme settings. Reopen qcam after changing display scale. [Qt Xcb DPI handling](https://github.com/qt/qtbase/blob/v6.8.2/src/plugins/platforms/xcb/qxcbscreen.cpp#L88) · [Qt scaling](https://github.com/qt/qtbase/blob/v6.8.2/src/gui/kernel/qhighdpiscaling.cpp#L253)

## Build and install

Use the authenticated libcamera source archives and pinned Asphalt checkout. Add Trixie's `qt6-base-dev` and `libqt6opengl6-dev` to the build environment. The upstream binary links the Qt OpenGL frontend even when launched with the raster renderer. The qcam package revision is independent and depends on `y700-camera-runtime (= 0.7.2-1~bpo13+1.y7001)`. [Camera runtime build](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access)

```sh
SOURCE_DATE_EPOCH=1795095900 bash scripts/build-camera-backport.sh --qcam "$sources" "$asphalt" "$out"
sudo apt-get --no-install-recommends install "$out"/y700-camera-qcam_0.7.2-1~bpo13+1.y7002_arm64.deb
```

On the verified 1050-package ARM64 image, APT selected 17 additional Debian packages with zero upgrades or removals. The app archive was about 106 KB. The full addition was 8.43 MB in archives and 33.6 MB installed. The optional [Debian archive lock](../config/camera-qcam-debian-auth.lock.json) matches those 17 packages against signed Trixie metadata. The lock describes the snapshot used for this test.

On an offline disposable copy of that image, fetch the locked archives on a connected build host and copy them with the app archive into the installation environment. Install them together. `sudo apt-get purge y700-camera-qcam` removes the application and leaves the camera runtime installed.

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
  --lock config/camera-qcam-debian-auth.lock.json --cache "$qcam_deps"
sudo dpkg -i "$qcam_deps"/*.deb "$out"/y700-camera-qcam_0.7.2-1~bpo13+1.y7002_arm64.deb
sudo apt-get check
```

To include the app in a new image, start with a disposable ARM64 build root that already has the [camera runtime layer](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access). Place the reviewed app archive and all 17 Debian archives together in an empty staging directory. Hard links work when the archives and staging directory share a filesystem. The installer checks the package tuples, sizes and SHA-256 against the [image layer lock](../config/camera-qcam.lock.json) and records the package inventory. A rebuild with a different archive hash requires a reviewed lock update.

```sh
mkdir "$qcam_layer"
ln -- "$qcam_archive" "$qcam_deps"/*.deb "$qcam_layer/"
sudo env UV_BIN=/path/to/uv bash scripts/add-board-layer.sh camera-qcam "$root" "$qcam_layer"
```

## Verification

The optional layer installed offline in a disposable overlay of the 1050-package image. The full 1068-package inventory matched the input locks, and the installer rejected a modified archive before installing any packages. In a separate camera-free ARM64 Xvfb session the `y700` user opened the installed desktop entry. The chooser appeared and closed in response to Cancel. The process mapped the private libcamera and Qt's Xcb platform plugin without loading an Xcb GL integration plugin. Package removal preserved the existing `cam --list` entry point. Run the fixture with `xvfb` and `xdotool` installed in the disposable environment. [X11 fixture](../tests/camera-qcam-x11.sh)

The ARM64 X11 scale fixture runs real Xfsettingsd and substitutes the Y700 connector name in the virtual RandR report. With the prior launcher, the chooser measured 246×124 pixels at both 100% and 200%, although Thunar grew from 640×480 to 1280×960. The revised launcher produced 492×248 pixels at 200% in portrait and landscape. Custom Xft DPI and explicit Qt scaling took precedence. The fixture also checks a second active output, another desktop and missing Xft DPI. Reproduce with `bash tests/camera-qcam-x11.sh --scale` in a disposable Xfce environment. [X11 scale fixture](../tests/camera-qcam-x11.sh)

The independently built `y7002` ARM64 archive is 106,716 bytes and has SHA-256 `2ce3ec833c4b609c3cfa0e38346530e9d07267c0d2192db5c7a4a2d050c5a972`. Its native qcam `.text` section matched the prior build byte for byte. An offline APT simulation selected only the app upgrade. The installed archive passed all nine X11 cases. Reinstalling `y7001` restored the original package inventory, launcher bytes and 246×124 chooser at 200%. The updated application lock applies to future image assembly.

The earlier `y7001` app archive has SHA-256 `a89c0b4bc3793c36359c45cf7c0840ea03e9de219128715785c73bff113444b0`. On the tablet it installed alongside 17 new dependencies. The package audit, APT dependency check and original LightDM invocation passed after installation. The recorded dev9 image uses that revision. Its package inventory corresponds to the lock files from the dev9 build.

In an unattended hardware run, the current greeter seat's unprivileged account started the installed launcher with Qt's offscreen platform and the CPU ISP. Seven-second runs received 95 main, 202 front and 202 macro viewfinder frames, each 640×480 ABGR8888. The test checked buffer lengths and sequence order and closed each app cleanly. It saved no photographs. The visible camera picker and preview on the internal panel, touch operation, still-image quality and switching within a single session need an attended test. [Hardware viewfinder fixture](../tests/qcam-tablet-preview.sh)
