# Iris VP9 first picture on TB320FC

The private GStreamer plugin delivered all 24 reference pictures on the PRC tablet at both 384×256 and 1920×1080. Both VP9 runs reached end of stream. In the 1080p WebM test, automatic GStreamer selection chose `v4l2vp9dec` and no separate parser was needed. The installed Debian plugin stays available to ordinary applications. The trial bundle is optional. [Codec wiring](VIDEO-CODEC-KERNEL.md)

## Optional Parole bundle, revision 2

Revision 2 includes the VP9 first-picture correction and adds support for two partial BT.601 descriptions on the compressed input of Iris. The 135,543-byte archive `out/iris-input-color-r2/iris-input-color-r2-arm64.tar.gz` has SHA-256 `14d9ffb3bf32373e44d460904168fd7227f987ce76a4051e566b6d7d5e053d0f`. It contains `PRIVATE-SHA256SUMS` and one private ARM64 plugin, SHA-256 `7c3e57f206c81fa0af09a3cf34d9836a686527212c7738dc4657d6c315ec9962`. The per-process extraction and checksum procedure below applies to either revision.

On the physical tablet, opening each 1920×1080 file in Thunar launched Parole. The ordinary user saw three expected picture changes in each video on the isolated X desktop. Each Parole process returned ten buffers from its matching Iris decoder during observation. In separate runs through end of stream, all 48 decoded pictures for each format exactly matched the software reference. The device returned to runtime suspend after each run. The images, packages and preferences for the desktop trial were staged in RAM. Local receipts are `out/iris-physical/parole-thunar-10.log`, `parole-10.tar.gz` and `color-r2-{h264,hevc,vp9}-playbin.log`.

| Codec | Original 1080p 12 fps clip at the decoder input | 1080p 2 fps Parole clip at the decoder input |
| --- | --- | --- |
| H.264 | No colorimetry field, parsed Annex B access units | `0:4:0:0`, parsed Annex B access units |
| HEVC | No colorimetry field, parsed Annex B access units | `2:4:0:0`, parsed Annex B access units |
| VP9 | `2:0:0:0`, with or without the additional VP9 parser | `2:4:0:0`, profile 0 |

The four numbers describe range, matrix, transfer function and primaries. Zero denotes unknown. Both failing descriptions explicitly identify the BT.601 matrix. The second also specifies limited range. The driver advertised `bt601` and `2:0:0:0` among its supported settings. GStreamer treats the colorimetry field as a string. The stock V4L2 plugin supplies a colorimetry-free alternative for raw video only. With a partial description on the compressed input, each Iris decoder opened and reached READY before `ACCEPT_CAPS` failed. Parole then displayed software-decoded pictures. The archived trial 08 showed this for all three codecs. Replaying its exact caps on ARM64 found that removing only colorimetry restored the stock caps intersection in all three cases. [GStreamer color representation](https://gstreamer.freedesktop.org/documentation/video/video-color.html) · [V4L2 caps probing](https://github.com/GStreamer/gstreamer/blob/1.26.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2object.c)

The revision adds two alternatives to the probed compressed sink caps only when this board's Iris decoder advertises full `bt601` on that codec. Every other field and memory feature is copied from the original alternative. The stream retains its own range and matrix, and its unspecified primaries and transfer function. The fix introduces no new full-range, PQ or HLG alternatives. The original raw CAPTURE path still negotiates the decoded surface. In the physical trial 10 trace, the decoder accepted each of the three original input strings. [Caps change](../tests/video-vp9/iris-input-color.h)

Two clean builds reproduced both revision 2 and the original revision 1 archive. ARM64 tests covered 15 color/format/device cases, the three full trace intersections and the 13 earlier VP9 buffer replays. The local color receipt `out/iris-input-color-r2/color-replay.log` has SHA-256 `0f811918322d7cb5ae43ca67dee952a9cd923d66cafe56a401e378022e91277a`. Use `build-color.sh` with the same inputs as the original builder below. The caps test can be compiled with an ARM64 C compiler and `pkg-config --cflags --libs gstreamer-video-1.0`. Pass the compiled test or its QEMU command to `check-color-trace.py` after the path to `parole-08.tar.gz`. [Revision 2 builder](../tests/video-vp9/build-color.sh) · [ARM64 checks](../tests/video-vp9/color-caps.c) · [Trace replay](../tests/video-vp9/check-color-trace.py)

## The two capture buffers

The stock Debian 1.26.2 V4L2 decoder delivered 23 of 24 pictures from the short synthetic clip. Its first output matched the **second** software reference picture. The remaining pictures matched in order. GStreamer's V4L2 allocator logged the following CAPTURE buffers returned by the kernel, with a separate OUTPUT dequeue interleaved. Both CAPTURE buffers carried sequence zero and copied timestamp zero.

| CAPTURE index | Flags | Payload at 384×256 | GStreamer stock behavior |
| --- | --- | --- | --- |
| 0 | `0x4041` (MAPPED, TIMESTAMP_COPY, ERROR) | 0 of 147,456 bytes | Emits `capture-error-dequeued`. The decoder drops pending frame zero. |
| 1 | `0x4009` (MAPPED, TIMESTAMP_COPY, KEYFRAME) | 147,456 of 147,456 bytes | Looks up frame zero again. The pending frame has already been dropped. |

The Iris HFI Gen2 response code can set ERROR on firmware-reported corruption or overflow. It also sets ERROR when a streaming non-LAST output has no data. A separate branch recycles a picture explicitly identified as NOSHOW. The observed V4L2 flags alone cannot identify the firmware's reason. In the plugin, the capture-error signal runs before raw memory is resized to the negotiated picture size. Those details make the kernel's raw `bytesused` and the following actual dequeue necessary to distinguish this event pair. [Asphalt patch series](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/series.nix) · [GStreamer buffer pool](https://github.com/GStreamer/gstreamer/blob/1.26.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2bufferpool.c) · [GStreamer decoder](https://github.com/GStreamer/gstreamer/blob/1.26.2/subprojects/gst-plugins-good/sys/v4l2/gstv4l2videodec.c)

The trial recognizes the first CAPTURE of a stream on the `aa00000.video-codec` Iris Decoder with VP9 input and NV12 multi-planar capture. It requires one memory plane, a zero offset and the exact empty-error signature. It returns that slot to the pool and waits for one more CAPTURE using the normal interruptible dequeue. A full, error-free keyframe at the same zero sequence and timestamp confirms the pending picture. A different return reports the original capture error. A second error also retains its own signal. A flush, device failure, source change or end of stream reports the pending error before returning the original flow status. The implementation submits each compressed input through the existing decoder path once. [Plugin patch](../tests/video-vp9/iris-vp9.patch)

## Evidence and scope

| Check | Result |
| --- | --- |
| Board, stock plugin | 23/24 pictures, missing reference picture zero. Local trace `out/iris-physical/vp9-capture-flags.log` |
| Board, unmodified plugin rebuilt with the candidate's toolchain | 23/24 again. The first delivered frame matched reference 2 and the last matched reference 24. Local trace `out/iris-physical/vp9-same-build-stock.log`, SHA-256 `9688d4e31f2d3b3829786211c35e282cf0850dfc4ea7dc8e0f0e2a30c6cb5083`. |
| Board, private plugin, direct decoder | 24/24 software frame matches, 384×256, EOS. Local receipt `out/iris-physical/vp9-private-small.log` |
| Board, private plugin, WebM automatic selection | 24/24 software frame matches, 1920×1080, EOS. Local receipt `out/iris-physical/vp9-private-hd-auto.log` |
| PC, native ARM64 code under QEMU | 13/13 dequeue replays. Divergent timestamp/sequence, partial payload, delta frame, two errors, EOS on poll, a dequeued LAST buffer, flushing, source change, device failure and an ineligible stream all preserved the expected error signals and flow returns. A damaged first picture with payload stayed marked corrupt. Local receipt `out/iris-vp9-private/replay.log` |

The PC replay uses the compiled plugin pool code, GStreamer buffers and GObject signals. Its three simulated operations are hardware polling, kernel dequeue and buffer return. The two tablet runs used the real VPU and returned to runtime suspend with the original boot, services, seat and brightness. Qualification covers the recorded short clips and the tested linear NV12 route. Longer streams, seeking, ten-bit VP9 and browser playback need their own application evidence. [Replay harness](../tests/video-vp9/replay.py)

## Private bundle and reconstruction

The 135,070-byte archive `out/iris-vp9-private/iris-vp9-arm64-trial.tar.gz` has SHA-256 `ae9914454049bb40b6e47f85e13d7dfd989f66d1c82fad6e55b054c8040dbb82`. It contains a checksum and `private/libgstvideo4linux2.so` (402,968 bytes, SHA-256 `6ee8ed61c80e19920f744330ae98cb2db19d7df0b9d0689c35ddaf8f6286391d`). After extraction in a new directory, run `sha256sum -c PRIVATE-SHA256SUMS`. A test process can prepend the extracted `private` directory to `GST_PLUGIN_PATH_1_0` and use a fresh private path for `GST_REGISTRY_1_0`. Check the selected plugin's filename in that process. Closing the test and using the normal environment restores system plugin selection.

The build uses Debian's `gst-plugins-good1.0 1.26.2-1+deb13u2` source. The Trixie InRelease signature and the signed main Sources index were checked on the PC. The index SHA-256 is `ae99131b13c7e61c53a52c33a2f9088a1bc5db15a664f5d90cc3753ad9b65606`. The builder checks the source archive hashes, applies the Debian series, builds the stock control and then applies only the local change. It enables V4L2 probing, GUdev and libv4l2. Independent clean builds produced identical stock and private ELF files. The matched unpatched rebuild has SHA-256 `c1e31305ac12f33aa46d29b9eed50ae1880670c2ce605c0712bec4fa1df67e53`. [Debian source archive](https://deb.debian.org/debian/pool/main/g/gst-plugins-good1.0/) · [Build script](../tests/video-vp9/build.sh)

The builder accepts the four pinned source files, a new work directory and an optional Meson cross file. Use an ARM64 Debian development sysroot with GStreamer 1.26.2 core/base, GLib, GUdev and libv4l development files. Supply the Python environment containing Meson through `MESON_PYTHON` and the target strip tool through `STRIP`. In a cross build, run the replay with the same sysroot and an empty plugin search path.

```sh
bash tests/video-vp9/build.sh "$DEBIAN_SOURCE_ARCHIVES" "$NEW_BUILD" "$ARM64_CROSS_FILE"
uv run --offline --no-project python tests/video-vp9/replay.py "$NEW_BUILD/obj" "$NEW_REPLAY"
GST_PLUGIN_SYSTEM_PATH_1_0= GST_PLUGIN_PATH_1_0= GST_REGISTRY_FORK=no \
  GST_REGISTRY_1_0="$NEW_REPLAY/registry.bin" qemu-aarch64 -L "$ARM64_SYSROOT" "$NEW_REPLAY/replay"
```
