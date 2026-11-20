# Optional Y700 Camera desktop application

`y700-camera-qcam` packages the upstream libcamera 0.7.2 Qt camera viewer for Debian 13 ARM64. Xfce shows **Y700 Camera** under Graphics. The launcher uses the existing `y700-camera-runtime` in `/opt/y700-camera`, selects the CPU software ISP and opens the X11 Qt raster viewfinder with Xcb GL integration disabled. Upstream qcam includes camera selection, start and stop, and still-image save controls. [qcam source](https://git.libcamera.org/libcamera/libcamera.git/tree/src/apps/qcam?h=v0.7.2)

On Xfce X11, revision `y7002` gives qcam a 2× scale when the sole active output is the native Y700 panel, Xfce requests 200%, and X11 actually publishes the standard 96 Xft DPI. The launcher's fallback respects custom Xft DPI and explicit Qt scale, DPI or platform-theme settings. Reopen qcam after changing display scale. [Qt Xcb DPI handling](https://github.com/qt/qtbase/blob/v6.8.2/src/plugins/platforms/xcb/qxcbscreen.cpp#L88) · [Qt scaling](https://github.com/qt/qtbase/blob/v6.8.2/src/gui/kernel/qhighdpiscaling.cpp#L253)

## Take a photo

Open **Y700 Camera**, select a camera and tap **Take photo** (**拍照** in a Chinese locale). The shutter sits below the viewfinder and becomes available when a frame arrives. The app saves a JPEG in the desktop user's Pictures folder and shows the path at the bottom. Each tap gets a new filename. **Save As** still lets you choose a filename or PNG.

Revision `y7003` requests the largest processed size advertised for the selected raster viewfinder format. An explicit `--stream` takes precedence. The camera validates the configuration, and the shutter copies the current frame at its actual pixel dimensions before encoding it on a worker thread. Screen layout and desktop scale do not set the JPEG size. The CPU debayer reserves an interpolation border, so its output can be slightly narrower than the sensor's RAW frame. [Tablet changes](../packaging/camera-qcam/tablet-photo.patch) · [Upstream Debian-version qcam](https://github.com/libcamera-org/libcamera/blob/v0.7.2/src/apps/qcam/viewfinder_qt.cpp) · [Qt Pictures directory](https://doc.qt.io/qt-6/qstandardpaths.html)

## Build and install

Use the authenticated libcamera source archives and pinned Asphalt checkout. Add Trixie's `qt6-base-dev` and `libqt6opengl6-dev` to the build environment. The upstream binary links the Qt OpenGL frontend even when launched with the raster renderer. The qcam package revision is independent and depends on `y700-camera-runtime (= 0.7.2-1~bpo13+1.y7001)`. [Camera runtime build](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access)

```sh
bash scripts/build-camera-backport.sh --qcam "$sources" "$asphalt" "$out"
sudo apt-get --no-install-recommends install "$out"/y700-camera-qcam_0.7.2-1~bpo13+1.y7003_arm64.deb
```

On the verified 1050-package ARM64 image, APT selected 17 additional Debian packages with zero upgrades or removals. The app archive was about 106 KB. The full addition was 8.43 MB in archives and 33.6 MB installed. The optional [Debian archive lock](../config/camera-qcam-debian-auth.lock.json) matches those 17 packages against signed Trixie metadata. The lock describes the snapshot used for this test.

On an offline disposable copy of that image, fetch the locked archives on a connected build host and copy them with the app archive into the installation environment. Install them together. `sudo apt-get purge y700-camera-qcam` removes the application and leaves the camera runtime installed.

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
  --lock config/camera-qcam-debian-auth.lock.json --cache "$qcam_deps"
sudo dpkg -i "$qcam_deps"/*.deb "$out"/y700-camera-qcam_0.7.2-1~bpo13+1.y7003_arm64.deb
sudo apt-get check
```

To include the app in a new image, start with a disposable ARM64 build root that already has the [camera runtime layer](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access). Place the reviewed app archive and all 17 Debian archives together in an empty staging directory. Hard links work when the archives and staging directory share a filesystem. The installer checks the package tuples, sizes and SHA-256 against the [image layer lock](../config/camera-qcam.lock.json) and records the package inventory. A rebuild with a different archive hash requires a reviewed lock update.

```sh
mkdir "$qcam_layer"
ln -- "$qcam_archive" "$qcam_deps"/*.deb "$qcam_layer/"
sudo env UV_BIN=/path/to/uv bash scripts/add-board-layer.sh camera-qcam "$root" "$qcam_layer"
```

## Verification

On Debian ARM64 with Qt 6.8.2, the photo storage test decoded 13 sequential and concurrent synthetic JPEGs and checked their pixel dimensions, colour patterns and unique paths. A forced short write left the destination clean and a subsequent save succeeded. To reproduce on a build host, pass the patched libcamera source tree to the [Qt storage test](../tests/qcam-photo/run.sh).

The physical TB320FC upgraded from `y7002` to `y7003` in a single application package transaction. The 110,388-byte ARM64 archive has SHA-256 `f04073685168c81a8a20d3f078f8825df559cc75260916759f58771f335e0c36`. The installed app matched the archive, APT and dpkg checks passed, and the original boot, LightDM, SSH and Bluetooth service invocations continued. The previous `y7002` archive and its rollback script are retained on the tablet.

Two builds from separate source trees with a shared compiler cache produced the same archive. An offline upgrade in a disposable copy of the dev12.4 image changed only this package. All nine X11 chooser and scaling cases passed. Restoring `y7002` recovered the original 1,112-package inventory.

In a full-system ARM64 QEMU boot, the exact `y7003` qcam ELF used a test-only libcamera virtual camera. At 200% scale, a single X11 click on the 224×96-pixel shutter produced exactly one 800×600 JPEG. An independent decoder verified the eight colour bars, and the viewfinder received further frames. The test deleted the image. This covers the app and JPEG workflow with a known source. [Virtual camera fixture](../tests/qcam-photo/run-virtual-qemu.sh)

The [tablet still-photo fixture](../tests/qcam-tablet-photo.sh) uses an isolated X11 display and a private tmpfs Pictures folder. It takes one photo per lens, checks that each JPEG fully decodes at the configured stream dimensions, removes it and waits for the next preview frame. Run it with the owner's permission to activate all three cameras. It needs `Xvfb`, `xdotool`, `uv`, AT-SPI and GdkPixbuf.

The optional layer installed offline in a disposable overlay of the 1050-package image. The full 1068-package inventory matched the input locks, and the installer rejected a modified archive before installing any packages. In a separate camera-free ARM64 Xvfb session the `y700` user opened the installed desktop entry. The chooser appeared and closed in response to Cancel. The process mapped the private libcamera and Qt's Xcb platform plugin without loading an Xcb GL integration plugin. Package removal preserved the existing `cam --list` entry point. Run the fixture with `xvfb` and `xdotool` installed in the disposable environment. [X11 fixture](../tests/camera-qcam-x11.sh)

The ARM64 X11 scale fixture runs real Xfsettingsd and substitutes the Y700 connector name in the virtual RandR report. With the prior launcher, the chooser measured 246×124 pixels at both 100% and 200%, although Thunar grew from 640×480 to 1280×960. The revised launcher produced 492×248 pixels at 200% in portrait and landscape. Custom Xft DPI and explicit Qt scaling took precedence. The fixture also checks a second active output, another desktop and missing Xft DPI. Reproduce with `bash tests/camera-qcam-x11.sh --scale` in a disposable Xfce environment. [X11 scale fixture](../tests/camera-qcam-x11.sh)

The independently built `y7002` ARM64 archive is 106,716 bytes and has SHA-256 `2ce3ec833c4b609c3cfa0e38346530e9d07267c0d2192db5c7a4a2d050c5a972`. Its native qcam `.text` section matched the prior build byte for byte. An offline APT simulation selected only the app upgrade. The installed archive passed all nine X11 cases. Reinstalling `y7001` restored the original package inventory, launcher bytes and 246×124 chooser at 200%. The updated application lock applies to future image assembly.

The earlier `y7001` app archive has SHA-256 `a89c0b4bc3793c36359c45cf7c0840ea03e9de219128715785c73bff113444b0`. On the tablet it installed alongside 17 new dependencies. The package audit, APT dependency check and original LightDM invocation passed after installation. The original dev9 bundle uses that revision and its corresponding package lock. The separate dev9 variant includes `y7002`. [Dev9 image variants](BOARD-IMAGE.md#dev9-image-with-the-scaled-qcam-chooser)

The running PRC tablet then upgraded to the verified `y7002` archive as a single package transaction. The installed application ELF matched the archive. `dpkg -V`, `dpkg --audit` and `apt-get check` passed, and the boot and SSH, LightDM and BlueZ service invocations continued. A verified `y7001` archive and rollback script were retained. The physical Qt chooser remains to be tested.

In an unattended hardware run, the current greeter seat's unprivileged account started the installed launcher with Qt's offscreen platform and the CPU ISP. Seven-second runs received 95 main, 202 front and 202 macro viewfinder frames, each 640×480 ABGR8888. The test checked buffer lengths and sequence order and closed each app cleanly. It saved no photographs. The visible camera picker and preview on the internal panel, touch operation, still-image quality and switching within a single session need an attended test. [Hardware viewfinder fixture](../tests/qcam-tablet-preview.sh)
