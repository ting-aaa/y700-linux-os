# dev12.13 userspace on the reference tablet

The same runner accepts a reconstructed dev12.15 `root.ext4` as its second argument with the ARM64 helper directory as its third and final argument. The host verifies the release root hash, compresses directly into the pinned USB transfer, and the tablet checks the decompressed bytes. On November 22 this took 37 seconds for 6 GiB. All 1,248 package tuples matched. The ordinary private 200% Xfce session ran Onboard and Quick Settings and opened the shipped Software Updates launcher. With the isolated system bus and empty cache it displayed the error, offered Retry and allowed the user to close. The four packaged USB sound modules were present in the sealed root. The physical tablet remained on the installed kernel throughout, and the post-test seat, services, storage, networking and camera counters matched. The log is `out/dev12.15-verified/physical-desktop-ram.log`.

The host streams the released `base/root.ext4.zst` over its pinned USB SSH connection. The reference tablet hashes the decompressed 6 GiB ext4, mounts it read-only with `noload`, and compares the ARM64 package ledger and all installed package tuples. The daily kernel remains running. An isolated Xfce at 2560 × 1600 and 200% scaling uses a temporary machine ID, a RAM overlay, empty hardware sysfs, a private bus and a private virtual display. The ordinary account stays locked in the released filesystem.

The reference run completed the 1,334,361,111-byte USB transfer in 55 seconds. Xfce autostart launched `y700-quick-settings --tray` as UID 1000 and acquired the application's session bus name. The packaged qcam opened from its desktop file. The chooser used three synthetic lens IDs and the actual English and Chinese labels. Both locales initially selected the main rear lens. Each run selected all three entries and cancelled before streaming. The namespace exposes no physical cameras or image buffer devices.

Available RAM was 13,839,196 KiB before staging and 13,839,964 KiB after cleanup. The owner seat, lock, boot and service identities, networking, backlight, remote sensor processor, camera power counters, ext4 mounts and error counts, loop devices and swap state matched. The complete log is `out/dev12.13-root/physical-ram.log` with SHA-256 `bf58acabc5ea91a74fbb87427d8830b0f234880ad1809d26d21ee51ce1491521`.

## Reproduction

Run on Linux or WSL with a host-key-pinned USB SSH wrapper for the reference tablet. The wrapper must pass its arguments as a remote root command and relay stdin. Supply the extracted release's `base` directory and an ARM64 helpers directory containing `bin/{Xvfb,xdotool,uv}` and `lib/libxdo.so.3`. For the camera chooser use the two fixture libraries built by the [camera orientation VM test](../qcam-photo/orient-vm.md) and the `libyuv0` archive pinned by [the camera fixture](../qcam-photo/virtual-runtime.sha256).

```sh
bash tests/tablet-desktop-ram/run.sh "$usb_ssh" "$release_base" "$arm64_helpers" \
    "$virtual_camera_libs" "$libyuv_deb"
```

The reference preflight checks the board model and dev12.11 host, sufficient available RAM and tmpfs space, clean writable inner and outer ext4, and the absence of swap. It requires all three physical sensors suspended, no running PipeWire camera source and no camera device holders beyond the existing PipeWire services. Device-side staging is confined to a new private directory under `/run`. Cleanup checks the before/after snapshot, mount namespace and loops and removes that directory.
