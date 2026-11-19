# Touch mapping across external-display changes

Run the packaged `/usr/bin/y700-display --watch` as the ordinary `y700` user on a private ARM64 Xorg display. A 1600×2560 virtual panel stays at the origin while a second 1600×2560 monitor is added on its right and removed. The test checks that the complete RandR line for the panel stays identical across both operations.

The Debian dummy video driver names the panel `DUMMY0`. The test translates this output name to `DSI-1` in the watcher's RandR results and back to `DUMMY0` in its XInput map request. The server supplies the desktop dimensions, XInput properties and events. The existing NT36523N Type-B uinput fixture feeds the kernel. Xorg loads libinput, and the test selects processed XI2 TouchBegin events from that touchscreen's device ID.

## Verified on dev10

Two contacts begin at 48% and 66% of the panel width, both at 47% of its height. Their expected panel positions are around (768, 1203) and (1056, 1203). The following coordinates are X server pixels.

| Watcher and action | Root width | Touch matrix X scale | Observed touch X positions |
| --- | ---: | ---: | ---: |
| dev9 watcher, add right-hand display | 3200 | 1 | 1535.9, 2111.8 |
| dev9 watcher started on both displays, then remove the second | 1600 | 0.5 | 384.0, 528.0 |
| dev10 watcher, add right-hand display | 3200 | 0.5 | 767.9, 1055.9 |
| dev10 watcher, replace matrix with identity while both displays are active | 3200 | 0.5 after repair | 767.9, 1055.9 |
| dev10 watcher, remove right-hand display | 1600 | 1 | 767.9, 1055.9 |

The dev10 watcher made four mapping writes over the full run, one each at startup, addition, matrix repair, and removal. Three further observed idle polls made zero writes. This covers Xorg's desktop mapping and window-system input coordinates. Both monitor connections and the digitizer in this test are virtual.

| Input | Version or SHA-256 |
| --- | --- |
| Dev10 QCOW2 leaf | `31ebe0e95e8c99eb915aa0c478d82b262c14c7c3b11863d85774f56b858b784e` |
| ARM64 kernel 7.3.4-asphalt-prc | `4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1` |
| Old helper at `cdbc282` | `21727b77f6e6409eb1dae764f02ab3fe0660c2f9e308f4bac41abed870ff492b` |
| Installed helper in `y700-platform 0.1.0~dev10` | `2c7119705d9e025124a1fc68565661f865c35c82eb8528f5b17f9dd4009af38c` |
| Shared `tests/touch-gestures/evdev-touch.c` | `7c539dbe6edb5553a6a8940eac30e8531829ac1fd0b7583d5aa8c5de5ece77d1` |
| Xorg server and Xorg libinput driver | `2:21.1.16-1.3+deb13u4`, `1.5.0-1` |

## Reproduce

Use the dev10 QCOW2 disk with its backing chain, the Y700 kernel, a static ARM64 BusyBox and Debian trixie ARM64 `xserver-xorg-video-dummy` version `1:0.4.0-1+b2`. The runner checks the dummy package SHA-256. The Linux host needs Bash, GNU utilities, cpio, gzip, an AArch64 cross compiler and qemu-system-aarch64.

```bash
old=$(mktemp)
git show cdbc282:src/session/y700-display > "$old"
bash tests/display-touch-topology/run-qemu.sh "$disk" "$kernel" "$busybox" "$dummy_deb" "$old"
rm -- "$old"
```

The VM uses 640 MiB, a read-only root disk and a disposable in-memory overlay. Its x86-64 host needs no display or input devices. A passing run prints `TOPOLOGY_PASS` and `TOPOLOGY_GUEST_EXIT=0`. The measured transcript at `out/display-touch-topology/dev10-extended.log` has SHA-256 `68645edd06067f12f383d3ffb8d227f63ccba33d912401f8f097ccd1a00be605`.
