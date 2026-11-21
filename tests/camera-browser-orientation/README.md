# Chromium camera orientation in the ARM64 desktop

The fixture drives the installed Chromium launcher, WirePlumber, PipeWire, and both the GTK camera and Chromium site permission prompts. The guest uses the sealed dev12.12 root read-only, a RAM overlay, an ordinary y700 account with a fresh temporary home, and loopback HTTP. Its modesetting Xorg server has a single VKMS DSI-1 connector. It has no network adapter or physical camera.

The virtual libcamera pipeline negotiates the physical tablet's measured `Rotate270` and front/back location for its three integrated camera IDs. Each virtual source has a distinct asymmetric colour chart. Debian's virtual pipeline omits the backing device numbers that WirePlumber uses for V4L2 deduplication. This VM supplies an empty list for that property inside the libcamera monitor. Camera capture, the SPA metadata, the portal backend, site permissions, WebRTC, and Chromium's X11 presentation use the real implementations.

For each of the main and front cameras the page opens the exact device, requests 640×480, and keeps the track open while the fixture sets the real DSI-1 CRTC to left and right. After eight successive presentation callbacks in each direction it classifies the four corners of the video. An independent reader identifies the mapped Chromium client window and classifies its chart. The guest records colours, counts and dimensions. It produces no exported images. A root observer verifies the unprivileged renderer's seccomp filter, `NoNewPrivs`, and separate PID namespace.

| Lens | CRTC | Expected upper-left, upper-right, lower-left, lower-right | Stock .4 | Candidate .5 |
| --- | --- | --- | --- | --- |
| Main | left | YBGR | BRYG | YBGR |
| Main | right | RGBY | BRYG | RGBY |
| Front | left | GRYB | YGBR | GRYB |
| Front | right | BYRG | YGBR | BYRG |

Stock presented 480×640 in both landscape directions. The corrected package presented 640×480. Coverage here applies to the controlled browser view, independent of qcam. Seeing an upright physical subject, or selecting or mirroring a camera in a conferencing application, needs an attended check on that application.

The tested .4 archive has SHA-256 `9de518b05da6d4fafc26a6a284dd30d484eb47801c947c814bcfa3fe772b3e52`. The independently built .5 archives matched byte-for-byte at `73cfdd2a0b1dad67f02aef3efbbb54b9129fb6a918bddc33b0574a08cd343cfc`. The historical backend builder without the display option also reproduced the original .3 archive at `f8c010932e9eb2a020a71bcc2a61cb322a24115e5b937a9e74ba4accd073c54d`.

## Reproduce

Use the kernel, VKMS module, read-only root, virtual runtime, uv, and signed dependency inputs described in [the qcam VM fixture](../qcam-photo/orient-vm.md). Run the following twice, first using `stock` and then the exact candidate Debian archive with a second log path.

```sh
bash tests/camera-browser-orientation/run-vm.sh \
    "$ROOT_EXT4" "$KERNEL" "$QCAM_Y7008_DEB" "$VIRTUAL_DEBS_DIR" \
    "$X11_DEBS_DIR" "$VKMS_KO" "$BUSYBOX_ARM64" "$UV_ARM64" \
    "$VIRTUAL_LIBS_DIR" stock "$NEW_STOCK_LOG"

bash tests/camera-browser-orientation/run-vm.sh \
    "$ROOT_EXT4" "$KERNEL" "$QCAM_Y7008_DEB" "$VIRTUAL_DEBS_DIR" \
    "$X11_DEBS_DIR" "$VKMS_KO" "$BUSYBOX_ARM64" "$UV_ARM64" \
    "$VIRTUAL_LIBS_DIR" "$CANDIDATE_DEB" "$NEW_CANDIDATE_LOG"
```

Set `QEMU_SYSTEM_AARCH64` and `QEMU_DATA_DIR` if using a private QEMU build. The fixture requires a new log path and checks the expected mismatch count. `BROWSER_ORIENTATION_DONE` and `PANEL_CI_EXIT=0` mark a complete run.

For the fresh dev12.14 installation, pass its reconstructed raw root and use
`installed` in both package positions. The guest checks the shipped versions and
files, verifies the installed qcam binary, and checks the SHA-256 and mapped inode of
WirePlumber's camera SPA. The ordinary Chromium user then runs the four chart
checks with a fresh private home. No replacement qcam or PipeWire package is in
the VM payload. [Installation and recorded checks](../../docs/DEV12.14-VERIFICATION.md)

```sh
bash tests/camera-browser-orientation/run-vm.sh \
    "$DEV1214_ROOT" "$KERNEL" installed "$VIRTUAL_DEBS_DIR" \
    "$X11_DEBS_DIR" "$VKMS_KO" "$BUSYBOX_ARM64" "$UV_ARM64" \
    "$VIRTUAL_LIBS_DIR" installed "$NEW_LOG"
```

To check the eight-byte user-session state on a Linux host, create a fresh temporary directory and run the native test.

```sh
w=$(mktemp -d)
mkdir -m700 "$w/runtime"
cc -O2 -Wall -Wextra -Werror -Ipackaging/camera-pipewire \
    tests/camera-browser-orientation/state.c -o "$w/state-test"
XDG_RUNTIME_DIR="$w/runtime" "$w/state-test"
```
