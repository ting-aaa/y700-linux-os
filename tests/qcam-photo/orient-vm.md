# qcam orientation on a rotating Xorg screen

This ARM64 VM runs the packaged qcam ELF on the sealed dev12.12 root. A VKMS connector named `DSI-1` drives the modesetting Xorg server. The test changes its live CRTC with RandR and checks the resulting connector geometry. At 200% Qt scale it compares four asymmetrical color markers inside the mapped qcam window with the decoded JPEG from the same camera's shutter. Each camera has a different original pattern and resolution. The JPEG and generated source frames live in the disposable guest. The host records text.

On the daily tablet, a configuration-only inspection found `Rotate270` for all three integrated sensors after requesting `Rotate0`. The virtual pipeline patch reproduces that negotiation, and a separate program checks all three lens IDs and facing properties inside the VM. The application's UI and capture code, Xorg rotation events, Qt rendering and JPEG encoding run normally. The owner separately confirmed that the real rear main preview is upright on the tablet after reopening the installed app. [Physical camera metadata and observation](../../docs/CAMERA-ORIENTATION.md)

| RandR rotation | Rear main and macro, clockwise | Front, clockwise |
| --- | ---: | ---: |
| left | 180° | 0° |
| normal | 90° | 90° |
| right | 0° | 180° |
| inverted | 270° | 270° |

The y7008 release package (`770adeb3…`) passed all 12 preview checks and all 12 decoded JPEG checks with the negotiated `Rotate270` fixture. At `left` the same rear main input appeared as red/green over blue/yellow in the y7007 control and yellow/blue over green/red in y7008, in both the window and the 800 × 600 JPEG. On that same CRTC the front output kept its original pattern and the macro output rotated by 180°. Both VMs exited successfully. The local receipts are in `out/qcam-orientation-vm/`.

Build the virtual libraries in the Debian ARM64 build environment used for the existing virtual shutter test. The host runner takes the two original package directories from that test, the matching guest-only VKMS module and the release root as a read-only raw image. The guest mounts a tmpfs overlay. The release camera runtime and tablet storage are outside the test.

```sh
bash tests/qcam-photo/orient-vm-build.sh "$libcamera_072_source" "$new_virtual_libs"
bash tests/qcam-photo/orient-vm.sh "$release_root" "$vkms_kernel" "$qcam_deb" \
    "$virtual_runtime_debs" "$x11_debs" "$vkms_module" "$arm64_busybox" "$arm64_uv" \
    "$new_virtual_libs" "$new_guest_log"
```

The y7007 control checks one rear preview and shutter at `left`. The y7008 run checks all 12 camera/rotation combinations in one process. Each row includes the CRTC, clockwise angle, preview and JPEG quadrants in top-left, top-right, bottom-left, bottom-right order, and the decoded size. The decoder reads the encoded pixel arrangement directly, without applying EXIF orientation. The package pins and repeatable test inputs are in [the host runner](orient-vm.sh).
