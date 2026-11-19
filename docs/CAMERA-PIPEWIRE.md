# PipeWire cameras and desktop camera permissions

On the TB320FC_PRC, an ordinary PipeWire client received 12 frames from each of the three physical cameras through the active LightDM greeter’s normal PipeWire and WirePlumber session. Each stream negotiated 640×480 RGBA and delivered 14,745,600 bytes with zero rejected frames. After the final camera package upgrade, three seconds of 48 kHz stereo digital silence drained over two active PipeWire links to the default CS35L45-protected speaker output at the original volume. The tablet stayed on the same boot. Audible balance and sound quality still require listening on the device. A separate video-only session reproduced all three results. After closing those streams, direct libcamera capture delivered six 640×480 ABGR8888 frames per sensor. The tests discarded the pixels. [Native capture probe](../tests/pipewire-camera.md) · [Direct capture and qcam evidence](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access)

| Camera | libcamera device path beneath `/base/soc@0/` | PipeWire node name |
| --- | --- | --- |
| Rear main · HI1339 | `cci@ac15000/i2c-bus@0/camera@20` | `y700_camera_rear` |
| Front · S5K4H7 | `cci@ac15000/i2c-bus@1/camera@10` | `y700_camera_front` |
| Rear macro · SC202CS | `cci@ac16000/i2c-bus@0/camera@36` | `y700_camera_macro` |

The Qualcomm CAMSS kernel drivers supply the sensor streams. The Asphalt board patches and libcamera simple pipeline convert Bayer data into colour frames. The optional `y700-camera-pipewire` package directs the private libcamera 0.7.2 runtime to use the CPU software ISP. WirePlumber assigns the names above and `media.role=Camera` by matching the board paths. PipeWire object serials can change every time the graph starts. [Asphalt sensor helpers and software ISP patches](https://github.com/dianqk/nixos-android-devices/tree/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/libcamera) · [Board rules](../packaging/camera-pipewire/65-y700-camera.conf) · [Private ISP configuration](../packaging/camera-pipewire/configuration.yaml)

## Build the camera backend

Debian Trixie builds its optional camera plugin for the distribution’s libcamera 0.4 ABI. The Y700 build uses the same PipeWire 1.4.2-1 source and compiles its camera plugin against the private 0.7.2 SDK. The two API adjustments cover the camera model string and the buffer-plane list. The plugin installs at `/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so`. Its own ELF RUNPATH resolves both `libcamera.so.0.7` and `libcamera-base.so.0.7` under `/opt/y700-camera/lib`. [Debian source](https://sources.debian.org/src/pipewire/1.4.2-1/spa/plugins/libcamera/) · [Compatibility patch](../packaging/camera-pipewire/libcamera-0.7.patch)

Use a Debian Trixie ARM64 build root with the camera runtime build dependencies and binutils. Supply the authenticated `libcamera_0.7.2-1` source archives and the pinned Asphalt checkout from the runtime build. Fetch `pipewire=1.4.2-1` with `apt-get source --download-only` from the signed Trixie source index into `$pipewire_sources`. Use absolute directory paths for the variables below and choose a new directory for `$sdk`. [Camera runtime dependencies and sources](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access)

```sh
CAMERA_SDK_OUTPUT="$sdk" bash scripts/build-camera-backport.sh \
  "$libcamera_sources" "$asphalt" "$runtime_out"
sudo apt-get install "$runtime_out"/y700-camera-runtime_0.7.2-1~bpo13+1.y7001_arm64.deb
bash scripts/build-camera-pipewire.sh "$pipewire_sources" "$sdk" "$plugin_out"
```

The builder verifies the Debian source archives, all 33 public SDK headers and both pkg-config files. Independent clean builds produced the same 53,928-byte ARM64 package, `y700-camera-pipewire_1.4.2-1+y700.3_arm64.deb`, SHA-256 `f8c010932e9eb2a020a71bcc2a61cb322a24115e5b937a9e74ba4accd073c54d`. Its SPA plugin, board camera rules and private CPU configuration match the first revision byte for byte. In a disposable copy of the 1,069-package image, PipeWire loaded that plugin’s enumeration manager and the signed simple IPA resolved in-process. The existing ALSA and V4L2 plugins, PipeWire core and private camera libraries matched their original bytes. [Builder](../scripts/build-camera-pipewire.sh) · [Plugin archive lock](../config/camera-pipewire.lock.json)

### Chromium on Xfce

After installing the optional plugin and both portal packages, quit Chromium and relaunch it from the ordinary Xfce menu. Debian’s `/usr/bin/chromium` reads `/etc/chromium.d/zz-y700-camera`, which enables `WebRtcPipeWireCamera` when the Y700 WirePlumber camera rule and the desktop portal and GTK backend executables are installed. Chromium still requests the website and desktop permissions. The launch configuration preserves the board’s GPU setting, Chromium’s sandbox and other enabled features, including field-trial parameters. An explicit `--disable-features=WebRtcPipeWireCamera` takes precedence. [Y700 Chromium configuration](../packaging/camera-pipewire/zz-y700-camera)

On an existing system with the private runtime installed, use `sudo apt-get install "$plugin_out"/y700-camera-pipewire_1.4.2-1+y700.3_arm64.deb` with an absolute output path. Removing the package with `sudo apt-get remove y700-camera-pipewire` also removes the board rule. At its next launch Chromium uses its previous flags, even if the portal packages and the locally edited Chromium conffile remain. `sudo apt-get purge y700-camera-pipewire` also removes the package’s conffiles.

## Add the two image layers

Start with a disposable KMS build root containing the camera runtime layer and platform dev7. Use separate archive directories for the private plugin and the 26 Debian portal packages. The portal set includes `xdg-desktop-portal` 1.20.3+ds-1 and its GTK backend 1.15.3-1. The offline solver selected the same packages for the original image and the existing tablet installation, with zero package upgrades or removals. [Debian archive lock](../config/camera-portal-debian-auth.lock.json) · [Portal image lock](../config/camera-portal.lock.json)

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
  --lock config/camera-portal-debian-auth.lock.json --cache "$portal_debs"
sudo env UV_BIN="$(command -v uv)" bash scripts/add-board-layer.sh camera-pipewire "$root" "$plugin_out"
sudo env UV_BIN="$(command -v uv)" bash scripts/add-board-layer.sh camera-portal "$root" "$portal_debs"
```

The tested overlay went from 1,069 to 1,070 packages with the plugin and to 1,096 with the portal. Its final package/version/architecture digest is `af3c9d2b39d671aab8b293284447ee0f68a5086e16687ac45f4dcf8781b68915`. A rollback restored the starting inventory. The 1,096-package derivative booted through EFI into systemd in QEMU with the same package digest. First-login evidence for the enrollment keyboard belongs to the original 1,069-package dev6 image. [KMS images and overlays](BOARD-IMAGE.md#kms-touchscreen-build)

## Test application access

Build the ARM64 probe with the [PipeWire camera test instructions](../tests/pipewire-camera.md). In the active desktop user’s session, list the sources, then use the serial printed for each sensor. The native probe verifies the graph link to the selected source and checks the buffer metadata.

```sh
./pw-camera-probe --list
./pw-camera-probe hi1339 "$rear_serial" 12 20
./pw-camera-probe s5k4h7 "$front_serial" 12 20
./pw-camera-probe sc202cs "$macro_serial" 12 20
```

Applications that use the desktop portal first request consent with `AccessCamera`. On grant, `OpenPipeWireRemote` supplies a file descriptor for a filtered PipeWire connection. Run this test in the target graphical session with the system Python and PyGObject available through uv. The consumer receives the authorized descriptor. A separate observer on the ordinary graph verifies the actual link to the requested camera. [Camera portal API](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Camera.html) · [Access client](../tests/camera-portal-access.py) · [Capture verifier](../tests/camera-portal-capture.py)

```sh
uv run --no-project --python /usr/bin/python3 python tests/camera-portal-capture.py \
  ./pw-camera-probe hi1339 "$rear_serial" 12 20
```

In an ARM64 Xvfb test, an ordinary desktop application used its own private session and a synthetic camera. Denying the GTK request returned response 1, and opening the remote then returned `NotAllowed`. On grant, the filtered connection exposed the Camera-role source and hid a Screen-role source visible on the ordinary connection. It delivered 12 RGB frames at 640×480, totalling 11,059,200 bytes with zero rejected frames. The 26 portal packages also installed on the tablet.

On the tablet, fresh X11 test desktops each used a private D-Bus, PipeWire service and permission store with the active seat's hardware access. Selecting **Deny Access** in the GTK dialog returned response 1, prevented the consumer from starting and made the portal refuse the descriptor. In a second desktop, selecting **Grant Access** exposed all three physical sensors. A client using only that descriptor received 12 RGBA frames at 640×480 from each camera, 14,745,600 bytes each with zero rejects. For every stream a separate observer saw the active link to the selected serial and the stream's removal. The test discarded the frames and used a disposable permission store.

On this tablet, Chromium 156.0.8078.47 originally reported zero video inputs to a loopback test origin. With the PipeWire camera feature enabled, its GTK camera dialog appeared and the same web page enumerated **Y700 Rear Camera**, **Y700 Front Camera** and **Y700 Rear Macro Camera**. For each name the page requested its exact device ID and 640×480, stopped the previous track, and confirmed 12 successive video presentation callbacks. Chromium presented each stream at 480×640. On a fresh profile the browser fixture also passed through both genuine prompts on a private virtual display. The test selected **Grant Access** in GTK and **Allow while visiting the site** in Chromium. A separate test chose **Never allow** in Chromium after granting the operating system request. The page reported denial, kept the camera selector disabled and opened no preview. All browser tests used the normal Chromium sandbox and board software-rendering setting. [Chromium capture factory](https://github.com/chromium/chromium/blob/main/media/capture/video/linux/video_capture_device_factory_linux.cc)

To repeat from the tablet, serve the [local browser test](../tests/camera-browser.html) on the loopback interface from the source checkout. Open the address below in Chromium, tap **获取摄像头**, choose a lens, then tap **采集 12 帧**. The page reports the track size and presented frame size. It stops the camera at 12 frames or when you tap **停止**.

```sh
uv run --offline --no-project --python /usr/bin/python3 python -m http.server 8765 --bind 127.0.0.1 --directory tests
# In Chromium, open http://127.0.0.1:8765/camera-browser.html
```

Attended work includes granting access by touch in the daily user session, checking the preview on the built-in panel, switching cameras in a third-party conferencing or Flatpak app, and evaluating orientation and still-image quality. Main-camera autofocus and rear flash have separate driver work. [qcam controls](QCAM.md) · [Focus and flash](CAMERA-FOCUS-FLASH.md)
