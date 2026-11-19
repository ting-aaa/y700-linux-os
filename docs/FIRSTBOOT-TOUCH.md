# First local password using the touchscreen

The optional `y700-firstboot-touch` package adds a framebuffer keyboard to the existing first-boot password prompt. On a new image the owner taps a password and enters it a second time. The original `passwd y700` and PAM handle both entries. The original service marks the account configured and continues to the display manager. Password login after that point belongs to the greeter.

The service wrapper starts its own Buffyboard process while the first-boot program owns tty1. It stops that process when enrollment finishes. A physical keyboard can enter the password throughout the process. An installation with `/etc/y700/user-configured` skips enrollment. The package contains a private executable and a drop-in for the existing first-boot service. [postmarketOS Buffybox](https://gitlab.postmarketos.org/postmarketOS/buffybox) · [Debian source](https://packages.debian.org/source/sid/buffybox)

## Build and add the optional layer

Trixie's tested ARM64 package index contains `unl0kr` for disk unlocking. The framebuffer keyboard used here is `buffyboard` from Debian's `buffybox 3.5.1+dfsg-2` source. Obtain that exact source from an authenticated Debian source index. Install Bash, dpkg-dev, Meson, Ninja, binutils, pkgconf, a C compiler, `libinih-dev`, `libinput-dev`, `libudev-dev` and `libxkbcommon-dev` in the Trixie ARM64 build environment. For cross compilation, supply a Meson cross file pointing to an equivalent ARM64 sysroot in `MESON_CROSS_FILE`.

```sh
cd "$sources"
apt-get source --download-only buffybox=3.5.1+dfsg-2
bash "$repo/scripts/build-firstboot-touch.sh" "$sources" "$debs"
cd "$debs"
apt-get download libinih1:arm64=59-1
bash "$repo/scripts/add-firstboot-touch.sh" "$disposable_root" "$debs"
```

The last command runs as root on the **build host** after normal platform integration and before board image assembly. Use a dedicated directory containing the two archives. The installer checks both against the [layer lock](../config/firstboot-touch.lock.json). Its root receipt feeds the image package verifier. A rebuild using another compiler or packaging-tool version can produce a different archive hash. Review the source, target ABI and build result before updating the lock. Rebuild the image from the original integrated root to omit the layer.

The build selects framebuffer output and omits upstream's optional always-on keyboard service. Its target ELF links to four Trixie libraries, `libc.so.6`, `libinput.so.10`, `libudev.so.1` and `libinih.so.1`. Only `libinih1 59-1` was absent from the 994-package dev5 root. Two independent builds with Clang 21.1.8, Meson 1.7.0 and the same Trixie ARM64 sysroot produced byte-identical archives matching the committed lock.

## Validation on 2026-11-19

A disposable ARM64 system VM booted the dev5 board image with a virtual 1024×768 framebuffer. The local account was initially locked. Linux classified the fixture's direct absolute input device as a touchscreen. The test tapped visible keys, pressed Enter, tapped the same independently generated password and pressed Enter again. The account became configured and the keyboard exited. The resulting credential matched the supplied test password, the normal Debian login PAM stack accepted that password, and a deliberately incorrect one failed. Test reports retained no test password or hash.

The optional package and its two-archive lock were also applied to a separate disposable dev5 ARM64 root. Its 996 installed package tuples produced SHA-256 `0340542ecd2e9e156f43546c5cef6b228b1ce539bf3efd5e1c320d64bf975b83`. Package audit, APT dependency check, unit validation and the already-configured early exit passed. Installation preserved the account database.

On the physical TB320FC_PRC, the original kernel provides `msmdrmfb`, `/dev/uinput` and the NT36523N touch driver. First-boot typing, panel orientation, key size, console prompt readability and handoff to the normal greeter on that screen still need an attended fresh-image trial.
