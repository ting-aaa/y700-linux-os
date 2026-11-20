# Playing video on the dev12.8 desktop

The sealed ARM64 image can play H.264 Baseline in MP4 and VP9 in WebM through Chromium. A fresh Xfce user has no default application for either file type. The GStreamer libraries also decode VP9 in software, including the first picture in the 24-frame file used on the tablet. These results come from the unmodified Debian applications in a QEMU guest with no video codec device.

| Entry point | H.264 Baseline / MP4 | VP9 / WebM | HEVC Main / MP4 (`hvc1`) |
| --- | --- | --- | --- |
| Chromium 156, HTML video over loopback | Six ordered pictures displayed, end of stream | Six ordered pictures displayed, end of stream | `MEDIA_ERR_SRC_NOT_SUPPORTED` |
| GStreamer 1.26.2, automatic local-file decoding without a VPU | Missing decoder | Six pictures byte-equal to lossless I420 reference | Missing decoder |
| Xfce file opening, GIO default for a fresh user | No handler for `video/mp4` | No handler for `video/webm` | Same `video/mp4` lookup |

The ordinary-user Xorg test sampled two pixels from the actual browser video frame on each presentation callback. Both successful clips displayed all six expected red/green, green/blue and blue/red pairs in order. The files contain no audio. The test uses the packaged browser executable and the desktop's existing defaults. It does not measure playback speed, power consumption, or the physical display.

## GStreamer on a tablet with Iris

The installed `gstreamer1.0-plugins-good` ARM64 plugin includes the optional stateful V4L2 device probe. Its shared object (`libgstvideo4linux2.so`, SHA-256 `844986bb49db504a7e5611af2496b4f80f85af74fdc6ce068f0d259fa9c1c93f`) contains the probe log message and the decoder implementation. Registration of `v4l2h264dec`, `v4l2h265dec` and `v4l2vp9dec` depends on the devices that the probing process can open and their advertised queues. In the guest, all three factories were absent and `v4l2src` was present. On the board, building a fresh registry can open codec nodes and start firmware. [GStreamer 1.26.2 V4L2 probe](https://github.com/GStreamer/gstreamer/blob/1.26.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2.c#L60-L97) · [Board kernel and firmware](VIDEO-CODEC-KERNEL.md)

An application opening ordinary MP4 also needs compatible packet framing. Iris advertises `H264` and `HEVC`. GStreamer maps both to byte-stream access units. MP4 commonly stores length-prefixed AVC or HEVC and supplies separate codec configuration. The baseline has `qtdemux` but has neither `h264parse` nor `h265parse` for conversion. Its package list also lacks the FFmpeg command, `libavcodec61`, `gst-launch-1.0`, `gst-inspect-1.0` and the GStreamer libav plugin. The test invokes the installed GStreamer C API directly. [V4L2 compressed format mapping](https://github.com/GStreamer/gstreamer/blob/1.26.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2object.c#L1569-L1583) · [H.264 parser](https://gstreamer.freedesktop.org/documentation/videoparsersbad/h264parse.html) · [H.265 parser](https://gstreamer.freedesktop.org/documentation/videoparsersbad/h265parse.html)

Iris exposes linear NV12 and P010 plus Qualcomm compressed `Q08C` and `Q10C`. GStreamer 1.26.2's V4L2 conversion table maps NV12 and P010 to known raw-video layouts. It has no corresponding entries for these two Qualcomm compressed formats. For an 8-bit CPU-readable frame, negotiate linear NV12 and honor the capture geometry reported after the source-change event. The visible rectangle, row stride, plane offsets and buffer extent all matter. The FFmpeg 7.1 stateful wrapper also contains linear NV12 and NV12M mappings. The Asphalt project packages additional FFmpeg changes for this board. [Linux stateful decoder contract](https://docs.kernel.org/userspace-api/media/v4l/dev-decoder.html) · [Qualcomm compressed formats](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-reserved.html) · [GStreamer raw mapping](https://github.com/GStreamer/gstreamer/blob/1.26.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2object.c) · [FFmpeg 7.1 mapping](https://github.com/FFmpeg/FFmpeg/blob/n7.1/libavcodec/v4l2_fmt.c) · [Asphalt FFmpeg changes](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/ffmpeg.nix)

## Two frame-level controls

* **Linear capture layout.** The fixture generates six NV12 frames, each with 192 × 112 visible pixels, 256-byte row stride, 128 allocated luma rows, UV offset 32,768 and 49,152 bytes per frame. It fills the padding with `0xa5`. The stock `rawvideoparse` and `videoconvert` elements reconstructed all 193,536 expected visible I420 bytes. This qualifies conversion of known linear buffers. Qualcomm compressed surfaces and 10-bit output need separate tests. [GStreamer rawvideoparse](https://gstreamer.freedesktop.org/documentation/rawparse/rawvideoparse.html)
* **Same VP9 file as the board comparison.** The ordinary local-file `uridecodebin` pipeline decoded all 24 distinct 384 × 256 pictures. Every visible I420 SHA-256 matched the reference in order, including picture one. WebM SHA-256 is `6c2148e9797c719252885000e7b907e0db2dfbf537a696d6816d0d1c3fd7030e`. The reference hash list has SHA-256 `f6d6536e1aa99d2d9b9d7f44ec980d95cd85e4c8bb7f1fe66e15a989ec293a9c`. The stock hardware path omitted the first picture of this file. A separately tested decoder plugin delivered all 24 on the tablet. [Physical VP9 diagnosis and fix](VIDEO-VP9.md)

## Repeat the test

The host needs QEMU AArch64, cpio, gzip, an ARM64 static BusyBox, an ARM64 uv binary and the Debian ARM64 Xorg dummy driver archive. The runner checks hashes of the sealed root, kernel and dummy driver, opens the root read-only and discards all guest writes at shutdown. The dummy Xorg driver lives only in the test overlay. The host clip generator uses FFmpeg with libx264, libx265 and libvpx. An existing executable can be selected with `--ffmpeg`. [Runner](../tests/video-userspace/run-qemu.sh) · [Clip generator](../tests/video-userspace/make-clips.py)

```sh
uv run --no-project --with imageio-ffmpeg==0.6.0 python \
    tests/video-userspace/make-clips.py out/video-userspace/new-clips
bash tests/video-userspace/run-qemu.sh "$DEV12_8_ROOT_EXT4" "$KERNEL" \
    "$ARM64_BUSYBOX" "$ARM64_UV" "$ARM64_XORG_DUMMY_DEB" \
    out/video-userspace/new-clips out/iris-clips-03/vp9
```

The last argument is optional. Supply the directory containing the 24-frame `clip.webm` and `reference.sha256` to run the same-file control. The full run ended with `VIDEO_USERSPACE_EXIT=0`. The reduced receipt at `out/video-userspace/sealed-dev12.8.log` has SHA-256 `639d1e9d10f252fba1d083937b4a60c3afbcd4d22fdd86a9053cfe69ad13c2a3`.
