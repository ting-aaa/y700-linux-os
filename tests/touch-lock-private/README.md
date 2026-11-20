# Private Xfce lock test

The runner uses a pinned USB SSH wrapper to exercise a candidate on an ARM64 tablet. It stages the three touch-lock archives and the older root's `libdbus-glib-1-2` dependency in `/run`, verifies both project locks and extracts the packages into a temporary directory. It uses the existing Xvfb and xdotool helper binaries from the directory passed on the command line.

```sh
bash tests/touch-lock-private/run.sh "$pinned_usb_ssh" out/touch-lock/archives "$device_helper_usr"
```

The trial runs with private mount, PID, IPC and network namespaces, a tmpfs root, a read-only `/usr` overlay, a private X display and D-Bus, and an empty `/sys`. Its device directory contains only null, zero, random and urandom. The PAM service comes from the exact screensaver archive. Its private `common-auth` uses Debian's pam_unix, pam_deny and pam_permit rules against a generated local account. Only the salted verifier is written to the private tmpfs. The checker drops its supplementary groups and privileges before starting the lock test. The randomly generated password stays inside the test process and its private authentication session.

The Xvfb screen is 2560×1600 with GTK scale 2. The test checks that the mapped Onboard plug and unlock dialog share a locker ancestor, measures the password entry without reading it and confirms the keyboard fits below it. Escape must dismiss the first prompt while the screen remains locked. On the second prompt the checker clicks the embedded Compact layout via X11, submits with Return and requires successful PAM authentication and deactivation of the private locker.

The runner compares the boot ID, active seat and lock hint, four service invocation IDs and installed package states before and after the trial. It enforces an 85-second namespace timeout, checks for leaked mounts and removes its staging directory. The physical panel, finger input and locking the owner's session require separate tests.
