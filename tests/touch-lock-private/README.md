# Private Xfce lock test

The runner uses a pinned USB SSH wrapper to exercise a candidate on an ARM64 tablet. It stages the three touch-lock archives and the older root's `libdbus-glib-1-2` dependency in `/run`, verifies both project locks and extracts the packages into a temporary directory. It uses the existing Xvfb and xdotool helper binaries from the directory passed on the command line.

```sh
bash tests/touch-lock-private/run.sh "$pinned_usb_ssh" out/touch-lock/archives "$device_helper_usr"
```

The trial runs with private mount, PID, IPC and network namespaces, a tmpfs root, a read-only `/usr` overlay, a private X display and D-Bus, and an empty `/sys`. Its device directory contains only null, zero, random and urandom. The PAM service comes from the exact screensaver archive. Its private `common-auth` uses Debian's pam_unix, pam_deny and pam_permit rules against a generated local account. Only the salted verifier is written to the private tmpfs. The checker drops its supplementary groups and privileges before starting the lock test. The randomly generated password stays inside the test process and its private authentication session.

The Xvfb screen is 2560×1600 with GTK scale 2. The test checks that the mapped Onboard plug and unlock dialog share a locker ancestor, measures the password entry without reading it and confirms the keyboard fits below it. Escape must dismiss the first prompt while the screen remains locked. On the second prompt the checker clicks the embedded Compact layout via X11, submits with Return and requires successful PAM authentication and deactivation of the private locker.

The runner compares the boot ID, active seat and lock hint, four service invocation IDs and installed package states before and after the trial. It enforces an 85-second namespace timeout, checks for leaked mounts and removes its staging directory. The physical panel, finger input and locking the owner's session require separate tests.

## Retry an incorrect password in the same dialog on a PC

`run-qemu.sh` boots the hash-pinned dev12.5 root read-only with the board's ARM64 kernel, no network adapter and a private 2560×1600 Xvfb desktop at GTK scale 2. It uses the normal ARM64 PAM helper and a generated test account with zero supplementary groups. The helper directory must contain ARM64 `bin/Xvfb`, `bin/xdotool` and `lib/aarch64-linux-gnu/libxdo.so.3`. The archive directory and its sibling `legacy-deps` use the same layout as the hardware runner.

```sh
bash tests/touch-lock-private/run-qemu.sh "$root_ext4" "$kernel_image" "$busybox_arm64" \
    "$uv_arm64" out/touch-lock/archives "$helper_usr"
```

The checker clicks Onboard's letter and Return keys to submit an incorrect password, waits for native PAM rejection and verifies that the locker remains active. It checks the masked field's length, sensitivity and editability without reading its contents. It then clicks the password field, checks focus, enters the correct password and submits using the embedded Return key. Success requires the same dialog process, dialog window and keyboard window throughout, one rejection, zero cancellations and successful PAM authentication. The earlier physical `out/touch-lock/private-native.log` covers the separate cancel-and-reopen path.

The November 20 full-system ARM64 run passed with one dialog and one keyboard. After PAM rejected the first submission, the empty, editable field already had focus. It stayed focused after the explicit tap and accepted the next password. The local receipt is `out/touch-lock/private-qemu-same-dialog-retry.log`, SHA-256 `b6ddb87cd9b59b2a07a648ae855cdf44b3b4a341bbbd119aca1e2954bad1a075`.

## Rotation during native lock and unlock

Append `--rotation-package "$platform_deb"` to the QEMU command above. The runner uses the rotation entry point, implementation and GSettings schema from that Debian archive and prints its version and SHA-256. An ordinary session process runs the client on the same D-Bus session as Debian's real Xfce screensaver. A separate private bus supplies a synthetic accelerometer and an active logind session whose `LockedHint` stays false. The display helper records each requested rotation.

After the client applies left, the sensor sends right and the fixture locks the desktop before the 3.5-second settling interval expires. The client must release its lease, ignore the pending right rotation, and issue no display request when the locked device changes to inverted. The normal Onboard/PAM exercise rejects a wrong password, then accepts the correct password in the same dialog. The client must obtain a new lease and apply the current inverted orientation. This fixture checks session policy and command dispatch. Real RandR, libinput coordinates and the tablet's inertial sensors have separate tests. [Display and direct-touch test](../rotation-touch/README.md)
