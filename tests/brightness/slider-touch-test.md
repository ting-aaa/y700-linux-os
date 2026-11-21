# Brightness slider with a Type-B digitizer

Run from a Linux host with QEMU, an AArch64 cross compiler, Bash, GNU cpio and gzip.

```bash
bash tests/brightness/slider-touch-run.sh "$dev1211_root_ext4" "$dev1211_kernel" \
    "$static_arm64_busybox" "$arm64_xorg_dummy_deb" "$arm64_uv" \
    "$gpu1_platform_deb" "$gpu1_1_platform_deb" "$gpu1_2_platform_deb"
```

The runner checks the root, kernel and package digests, boots the root read-only and installs the platform packages in order in a guest RAM overlay. Omit the last package to exercise the previous slider on the same display. It reuses the display topology fixture's Debian Xorg, libinput and portrait display. The D-Bus service behind `SetBrightness` accepts the internal KTZ8866 device name and updates a guest-private sysfs fixture. The GTK application runs as the ordinary `y700` user. The observer reads the accessible slider and button geometry. A single Type-B contact performs each drag and taps the restore button through the kernel and X server.

The pass line reports the logical touch target dimensions, kernel evdev tracking IDs and movement count, both drag results and the restored opening level. A separate trough tap establishes the exact expected level at the forward drag's release coordinate. The test covers application input and the D-Bus request path. Panel programming and luminance require hardware measurements.

## Measured on the sealed dev12.11 root

| Platform package | Tap at (1015, 1194) | Drag to the same pixel | Drag back to minimum | Tap restore | logind writes over all five contacts |
| --- | --- | --- | --- | --- | --- |
| `0.1.0~dev12.8+gpu1.1` | 80%, 1637 | 80%, 1637 | 5%, 102 | 400 | 27 in the recorded run, including intermediate writes during the drags |
| `0.1.0~dev12.8+gpu1.2` | 80%, 1637 | 80%, 1637 | 5%, 102 | 400 | 5 |

The virtual controller's range was 0–2047. GTK reported 377 × 56 logical pixels for both the slider and the restore button, equivalent to 754 × 112 display pixels. The five contacts produced 52 X-position updates. The complete guest transcripts are `out/brightness/slider-touch-old-atomic.log` and `out/brightness/slider-touch-fixed-atomic.log`.

An earlier fixture briefly exposed an empty regular file while updating the requested brightness. Under that condition the old application stopped partway through the drag. The comparison above publishes complete values with an atomic rename, matching the complete integer returned by the kernel attribute. Both packages reached the same drag endpoint in that comparison.
