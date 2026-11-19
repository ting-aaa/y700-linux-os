# First password on a DRM display

The optional `y700-firstboot-drm` package adds touchscreen password enrollment for boots using `drm_kms_helper.fbdev_emulation=0`. The 30-minute Adreno OpenGL and Vulkan experiments used that setting. The [framebuffer keyboard](FIRSTBOOT-TOUCH.md) and regular kernel console need a framebuffer device. The combined 1,050-package image retains its existing enrollment method and boot entry.

The DRM frontend is **unl0kr** from Debian's authenticated `buffybox 3.5.1+dfsg-2` sources, built specifically for Trixie ARM64 with the LVGL DRM backend. Buffyboard in the same source tree opens `/dev/fb0` directly. Debian 13's older unl0kr archive includes cryptsetup integration. This package ships a private executable and configuration for enrollment with Debian's existing `passwd` PAM stack. [Buffybox source](https://sources.debian.org/src/buffybox/3.5.1%2Bdfsg-2/) · [Upstream unl0kr](https://gitlab.postmarketos.org/postmarketOS/buffybox/-/tree/master/unl0kr)

## Build

Use the three authenticated Debian inputs listed in the [build script](../scripts/build-firstboot-drm.sh). The build requires the framebuffer package's Debian build prerequisites plus libdrm-dev, libpam0g-dev and patch. For cross builds supply a Meson cross file pointing to a Trixie ARM64 sysroot. The build host needs target binutils, Meson, Ninja and Debian packaging tools.

```sh
bash scripts/build-firstboot-drm.sh "$verified_buffybox_sources" "$out"
bash tests/firstboot-drm-output.sh
```

Install the resulting ARM64 archive in a disposable image containing `y700-firstboot-touch` and its dependencies. Installation adds a systemd drop-in without starting the service or creating a password. With framebuffer emulation enabled the service delegates to the existing Buffyboard wrapper. With it disabled the selector waits up to ten seconds for the internal DSI endpoint. It reads the DRM card and connector object ID from sysfs. Linux can report an unknown connection state before its first probe. The private frontend passes that exact ID to libdrm and proceeds when KMS reports a connected screen with a usable mode. On the target tablet the unprivileged selector reported card 1 and connector 36. The EFI test VM follows the same KMS check on its simple-framebuffer. A synthetic regression includes a disconnected DP output, a writeback connector and a separate connected external card.

The owner supplies a new password twice on the displayed keyboard. A USB keyboard can operate the same frontend. If the DRM output is unavailable, the existing tty password program accepts keyboard input. Console text visibility depends on the available console driver. Idle enrollment has no automatic poweroff timeout.

PAM receives each response over a private pipe. The account starts with the image's factory shadow value `!` and no `/etc/y700/user-configured` marker. Each attempt rechecks that state. Existing password hashes are preserved. The service recreates a missing marker for an already-active account. It preserves the marker and configured accounts and refuses other lock representations, including an administrative lock prefixed to an existing hash. An administrator who needs to keep a newly created, never-enrolled `!` account disabled can retain the configured marker. The original boot service continues to own tty1 and precedes LightDM. [Selector and adapter](../src/firstboot-drm)

Purging `y700-firstboot-drm` and reloading the systemd manager restores the installed framebuffer drop-in. Passwords and the enrollment marker remain in their existing locations. A fresh device on a framebuffer-disabled kernel needs the DRM package or another provisioned local input path.

## Verification on November 19, 2026

Two clean ARM64-targeted builds produced the same 260,752-byte `y700-firstboot-drm_0.1.0~dev1_arm64.deb`, SHA-256 `e89b6cb3ec78ab6f75e1e258ab651f80edf6e258bd320a8e0fd5707f8e420497`. An ARM64 EFI guest started from the combined 1,050-package root and candidate kernel on a disposable disk overlay. Kernel readback showed framebuffer emulation disabled, a simpledrm primary device and an absent `/dev/fb0`. Virtual scanout used card 0, connector 39. The optional archive installed offline and passed dpkg audit and APT dependency checks.

The normal systemd first-boot service showed the DRM keyboard. A virtual touchscreen entered two different passwords, and the next prompt appeared with the account still locked and the marker absent. The next two entries matched. The service wrote the marker, returned success, and LightDM started Arctica with Onboard. Independent Debian login PAM checks accepted the new password and rejected another one. The stored password hash matched the in-memory test input. The [account checks](../tests/firstboot-drm-states.sh) verified administrative lock preservation and the configured-marker early exit. Purging the package restored the framebuffer wrapper while keeping the running LightDM invocation, marker and password. The original image artifacts retained their hashes.

This test exercised ARM64 Linux DRM/KMS, the password UI and PAM on virtual simpledrm. Actual scanout and input on the Y700 panel, portrait/landscape layout, and the transition from a DRM-owned enrollment display to Xorg on the Qualcomm DPU require an on-device trial.
