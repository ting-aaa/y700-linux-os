# Touchscreen session locking

The sealed dev12.5 image has Xfce's `xflock4` frontend. In a full ARM64 EFI boot, a user enrolled through the virtual touchscreen and signed into Xfce through LightDM. Calling `xflock4` in that session returned status 1. The session remained active, logind reported `LockedHint=no`, and no greeter appeared. The image contains 1,112 packages and its installed-package digest is `ae129edd690fcd72820e3c286c6010474a70cefea622d53f4fe88b53f94afb21`.

The candidate installs Debian's `xfce4-screensaver` and `libxss1` with the board's `y700-touch-lock` settings. Xfce draws the lock screen in the user's X11 session. Onboard provides a Compact keyboard embedded in the unlock dialog. Debian's `xfce4-screensaver` PAM service authenticates the account. [Package lock](../config/touch-lock.lock.json) · [Xfce panel actions](https://docs.xfce.org/xfce/xfce4-panel/actions)

To lock an enrolled session, tap the account menu at the right end of the top panel and choose **Lock Screen**. Tap the dark screen to wake the prompt. Enter the account password on the on-screen keyboard and tap **Unlock** to return to the open desktop.

## Tablet deployment

The running tablet received four new packages. Its older desktop needed `libdbus-glib-1-2` from the existing warm-greeter lock in addition to the three session-lock packages. The install passed the APT dependency and dpkg checks. The installed package payloads matched the archives byte for byte, and a rollback script was retained. A subsequent SSH check found the original Xfce session still active and the new saver daemon absent from that session. Its normal desktop autostart takes effect on the next sign-in. Debian's default idle interval is five minutes and can be changed in Screensaver Preferences. The local installation record is `out/touch-lock/physical-install.log`.

Before deployment, an isolated Xvfb session on the tablet CPU exercised the native binaries at 2560 × 1600 with `GDK_SCALE=2`. The lock dialog embedded a 2560 × 410 Onboard keyboard. Tapping Cancel left the test session locked. Clicking the embedded keys to enter the temporary account's password unlocked the test session through PAM. The physical panel and a finger-operated lock/unlock cycle remain untested. The local record is `out/touch-lock/private-native.log`.

A separate PC-hosted ARM64 test at 2560 × 1600 and 200% scaling covered retrying in the same dialog. PAM rejected the wrong password. The input field cleared, became editable, and already had focus. The tester explicitly clicked it, then used Onboard's letters and Return key to authenticate. The dialog and keyboard identities stayed the same throughout. The local record is `out/touch-lock/private-qemu-same-dialog-retry.log`.

## Full EFI result

The unattended 1024 × 768 run opened the real Xfce account menu, selected **Lock Screen**, rejected the wrong password, kept the session locked after **Cancel**, and returned to the original desktop with the correct password. The same GTK process and mapped X11 window retained the entire unsaved draft and its modified flag. The guest powered down normally. The host rechecked the sealed root, EFI partition, virtual U-Boot and device tree against their input hashes. The reduced local record is `out/touch-lock/screen-lock-efi.txt` with SHA-256 `7326c01342876b5d1d715efee0f1cc111aaafab25acdb5db805b1ef9a6bc1db4`.

During this run, `org.xfce.ScreenSaver.GetActive` returned true at lock activation and after PAM rejected the password. It returned false after successful authentication. Logind reported `LockedHint=no` at all three points. The dev12.5 auto-rotation client reads the logind hint, so that client cannot detect this screen lock from the hint alone. The EFI run exercised the desktop with sensors disabled.

## Run the virtual test

Use the [combined EFI runner](../tests/combined-efi/README.md) with the documented sealed root, EFI partition, virtual U-Boot, and virtual device tree. Set `SCREEN_LOCK=baseline` to inspect the shipped image. For the candidate also supply `SCREEN_LOCK=candidate`, `SCREEN_LOCK_ARCHIVES` pointing to the locked Debian archives, and `UV_ARM64` pointing to an ARM64 Linux uv executable. The runner installs the candidates into a disposable snapshot after verifying the original package inventory.

The test opens a GTK window with an unsaved, randomly generated text buffer. An ordinary-user accessibility probe locates the session menu and its **Lock Screen** item on the 1024 × 768 virtual display. The host taps each using the direct Type-B input device. It checks the rendered Compact keyboard and submits a wrong password. After PAM records the rejection, the host taps the visible **Cancel** button. The guest checks that the old dialog closed while the lock stayed active. The host wakes a new prompt, taps the password field, and uses Onboard to enter the correct password. On return, the guest checks the original logind session, Xfce process, mapped X11 window and modified text buffer. The results go in `first/report.log`. The test keeps the enrollment password in host memory and discards the sampled frames.
