# Rear autofocus measurement

On the PRC tablet the [board runner](../camera-lens-graph/measure-board.sh) uses a transient ordinary-user service with a private network and a 70-second limit. Pass `--self-test` to run synthetic cases with camera devices hidden. The separately selected `--rear-af` mode measures a real scene; use it for a consented, attended trial with a suitable target. In both modes the runner checks that the rear sensor has returned to runtime suspend before exiting.

For a USB session, stage the runner as `measure-board.sh` and the executable in a new root-owned `mktemp -d /run/y700-af-optical.XXXXXXXX` on tmpfs. Give the directory and executable ordinary-user traversal and execution permissions. Invoke the staged runner with `--detached-rear-af EXECUTABLE`. It returns the transient service name and a private `receipt.log` path. After the service exits, read the receipt and look for both the terminal result and `AF_CLEANUP`. The log survives a USB disconnect within that boot. A reboot discards it. Both real-camera modes check root mount flags and hold a sleep inhibitor while the measurement runs.

Use a stationary, well-lit, textured target with visible fine edges near the centre of the preview. Keep the tablet and target still throughout the measurement. Each invocation of `--rear-af` opens the rear HI1339 for one 640×480 ABGR8888 viewfinder stream using the packaged CPU ISP. The sole actuator command is the normal libcamera `AfModeAuto` and `AfTriggerStart` pair in one request. The program neither creates a window nor encodes or saves images. The ordinary account running the measurement needs the same camera and dma-buf access as qcam.

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
| `no_gain` | The camera reported Focused and the scene passed the guards, but improvement over the initial position did not clear the threshold. An initially focused target can give this result. |
| `inconclusive` | The camera reported Focused, but texture, focus-score stability, clipping, illumination or scene consistency limited interpretation. |
| `af_failed` | The camera reported Failed. |

The independent sharpness metric averages the absolute four-neighbour green-channel Laplacian in the central half of the viewfinder, normalized by mean brightness. Eight-frame windows use the median score and the full score spread. Sixteen coarse, brightness-normalized tile means provide an in-memory framing guard. Output contains their aggregate distance only. The AF engine itself samples two-axis first differences. The independent measurement still responds to motion, noise, contrast and scene changes that escape the coarse guards. Its result describes that target at that distance and does not measure lens travel, absolute resolution or accuracy across distances.

Build against the y7002 runtime and libcamera 0.7.2 public headers on an ARM64 development root. The two include directories below correspond to the source and configured Meson build trees. The script runs the synthetic test before it publishes the executable.

```sh
bash tests/camera-autofocus/build-optical.sh \
  /build/camera-source/include /build/camera-build/include ./y700-af-measure
```

The client reuses completed request buffers and brackets each CPU read with dma-buf cache synchronization. [libcamera request API](https://docs.libcamera.org/master/public-api/classlibcamera_1_1Request.html) · [Linux dma-buf userspace access](https://docs.kernel.org/driver-api/dma-buf.html)
