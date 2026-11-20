# Authenticated Debian inputs and fresh package-base builder

The current lock selects **963 base packages** from authenticated historical Debian metadata. This is the original 962-package inventory plus `alsa-ucm-conf`, which supplies the top-level configuration required to load the Y700 speaker profile. The separate desktop repair lock still selects 30 packages. The package locks cover the selected archives. Filesystem reproducibility, security freshness and board support have separate checks.

## Provenance recovered and checked

The historical base's dpkg database contained 962 installed name/version/architecture tuples. The retained archives matched 957; apt, debian-archive-keyring, libapt-pkg7.0, login and sqv were missing. Their exact archives were retrieved from canonical Debian HTTPS repositories and verified against authenticated index hashes.

Retained public repository metadata from an earlier failed build made independent revalidation possible:

1. `gpgv` verified the original InRelease signatures against a separately installed Debian archive keyring (host package `2025.1ubuntu1`).
2. Every used uncompressed Packages index matched the signed Release SHA-256 and size.
3. All 962 requested package versions matched authenticated index entries, including each cached archive's length/hash. All 30 repair archives were also revalidated against their original signed indexes.

`config/debian-base.lock.json` and `config/desktop-repair-auth.lock.json` record repository/index hashes, dates, canonical archive URLs, versions, architectures, lengths and SHA-256. Keyring hash: `506b815cbb32d9b6066b4a2aa524071e071761e7e7f68c3ac74f3061ba852017`. The original acquisition filename list remains in `desktop-repair.lock.json`; renaming a byte-identical archive is allowed, while extra/missing packages or content changes are rejected.

**Freshness boundary:** base updates/security InRelease validity ended on 2026-10-30. Signatures remain useful for reproducing this historical snapshot, but do not make it a current secure release. A release candidate must refresh the snapshot and repeat acceptance with its exact versions. Runtime APT sources use normal signed Debian repositories; no globally disabled freshness/signature checks are installed.

## Rebuild on a Linux host

Prerequisites: mmdebstrap, dpkg tools, uv, root privileges and functioning ARM64 QEMU/binfmt support. A new root directory and repository directory are required. Build outputs and archives stay outside Git. Python always runs through uv.

For the current image inputs, build the dev12.8 platform archive at the epoch in the platform lock. The integration step checks that exact archive alongside the Debian repair inputs. [Platform archive lock](../config/platform.lock.json) · [Upgrade a sealed dev12.7 image instead](ADAPTIVE-BRIGHTNESS-IMAGE.md)

```sh
uv run --python 3.13 --no-project python scripts/fetch-debian-inputs.py \
  --lock config/debian-base.lock.json --cache downloads/debian-base
uv run --python 3.13 --no-project python scripts/fetch-debian-inputs.py \
  --lock config/desktop-repair-auth.lock.json --cache downloads/desktop-repair

sudo /path/to/uv run --python 3.13 --no-project python scripts/build-debian-base.py \
  --lock config/debian-base.lock.json --cache downloads/debian-base \
  --repository /build/package-repository --root /build/fresh-base
sudo bash scripts/configure-debian-base.sh /build/fresh-base
SOURCE_DATE_EPOCH=1795182000 bash scripts/build-platform.sh out/platform-dev12.8
sudo env UV_BIN=/path/to/uv bash scripts/integrate-rootfs.sh \
  /build/fresh-base downloads/desktop-repair out/platform-dev12.8/y700-platform_0.1.0~dev12.8_all.deb
uv run --python 3.13 --no-project python scripts/verify-image-packages.py /build/fresh-base
sudo env UV_BIN=/path/to/uv bash tests/arm64-rootfs.sh /build/fresh-base
```

### Optional camera development layer

The default integration leaves the camera layer out. To include it, use the fourth argument when integrating a fresh root. Obtain the six Debian archives from the authenticated camera lock and add the reviewed runtime archive to that directory. The integration checks each archive's Debian package name, version, architecture, size and SHA-256. It records the selected lock alongside the package inventory for image assembly. [Camera archive lock](../config/camera-layer.lock.json) · [Authenticated Debian source indexes](../config/camera-debian-auth.lock.json)

```sh
uv run --python 3.13 --no-project python scripts/fetch-debian-inputs.py \
  --lock config/camera-debian-auth.lock.json --cache /build/camera-debs
cp /private/reviewed/y700-camera-runtime_0.7.2-1~bpo13+1.y7001_arm64.deb /build/camera-debs/
sudo env UV_BIN=/path/to/uv bash scripts/integrate-rootfs.sh \
  /build/fresh-base downloads/desktop-repair out/platform-dev12.8/y700-platform_0.1.0~dev12.8_all.deb /build/camera-debs
uv run --python 3.13 --no-project python scripts/verify-image-packages.py /build/fresh-base
```

The default camera lock binds the exact development runtime used for the initial hardware capture. A source rebuild generates a new IPA signing key and may change package length and SHA-256. After checking the rebuilt package with its matching `cam`, IPA signature and GStreamer plugin, explicitly record a separate reviewed lock. An override can change the camera archive length and hash for this pinned runtime version. The six Debian archive tuples and digests remain fixed. [Private camera build and validation](CAMERA-SENSORS.md#bring-up-capture-and-desktop-camera-access)

```sh
uv run --python 3.13 --no-project python scripts/repair-inputs.py \
  record /build/camera-debs /build/camera-rebuilt.lock.json --camera-layer
sudo env UV_BIN=/path/to/uv bash scripts/integrate-rootfs.sh \
  /build/fresh-base downloads/desktop-repair out/platform-dev12.8/y700-platform_0.1.0~dev12.8_all.deb \
  /build/camera-debs /build/camera-rebuilt.lock.json
uv run --python 3.13 --no-project python scripts/verify-image-packages.py \
  /build/fresh-base --camera-lock /build/camera-rebuilt.lock.json
```

The earlier offline ARM64 integration test used a disposable dev5 overlay. It verified 1,001 installed tuples with digest `3ca13e620ff650d3b6e84dc6d539ee65c2cce450429e88ed8351306e660738c2`, a clean dpkg audit and startup of the private libcamera CLI. The lower dev5 root retained its exact 994-package inventory and dpkg status hash. This result covers the dev5 package and integration path.

The downloader publishes an archive atomically only after checking length/hash, revalidates cached files, and refuses a mismatched existing file. Tested network retrieval covered the five missing base packages and all 30 repair packages; all 962 base artifacts were additionally revalidated in the independent local pool. Future availability of every canonical URL is not guaranteed: use a reviewed historical Debian mirror/snapshot while retaining the exact content hashes if an archive is retired. Do not silently choose another version.

The builder creates a local repository exclusively from verified locked archives, then uses mmdebstrap with exact versions. Its `trusted=yes` applies only to this generated local repository; it is not used for a remote source. An empty suite is necessary for this flat repository, and the `copy:` transport puts archives into the chroot cache. These details fixed two observed failed builds (no essential packages selected, then inaccessible file-mirror archives). The builder checks the resulting installed package tuples against the entire lock before writing a success marker and restores normal authenticated runtime APT sources.

The configuration stage adds a locked local account, locales, default services and the existing console password setup. It deliberately does not claim touch-only graphical enrollment. It clears the base machine ID; later SSH package installation and test activity still require final identity/log cleanup before distribution.

### Optional Simplified Chinese input

The `chinese-ime` layer adds 15 Debian packages and the local `y700-input-pinyin` defaults package to the 1,096-package dev9 Bluetooth image. The dependency calculation used the installed ARM64 package database, the signed Trixie indexes and `--no-install-recommends`. It selected IBus 1.5.32-2, its GTK 3 input module, ibus-libpinyin 1.15.8-2 and im-config 0.57-2. The IBus archive includes the X11 input-method server. The base image supplies the Noto CJK fonts and its Qt 6 IBus input plugin. [Authenticated Debian archives](../config/chinese-ime-debian-auth.lock.json) · [Complete layer lock](../config/chinese-ime.lock.json)

Use a directory dedicated to this layer. The fetcher names each Debian archive after its SHA-256. The local package keeps its Debian filename. After staging, the directory can be copied to an offline build host. The layer installer configures the archives with dpkg and checks the local dependency database.

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
    --lock config/chinese-ime-debian-auth.lock.json --cache "$archives"
bash scripts/build-input-pinyin.sh "$archives"
uv run --no-project --python 3.13 python scripts/repair-inputs.py \
    verify "$archives" config/chinese-ime.lock.json
(export LC_ALL=C; cd "$archives" && sha256sum -- *.deb > SHA256SUMS && sha256sum --check --strict SHA256SUMS)
sudo env UV_BIN=/path/to/uv bash scripts/add-board-layer.sh chinese-ime "$root" "$archives"
```

Debian's im-config defaults to automatic selection on Xfce, including English-language sessions. It honors a user's `~/.xinputrc`. The local package supplies a direct US keyboard and the `libpinyin` engine as its default input-source list. Installing this optional layer leaves the system locale and existing user preferences in place.

To choose the desktop display language, open **Display language** in Xfce or run `gio launch /usr/share/applications/y700-display-language.desktop`. Select **简体中文**, log out, and sign in through LightDM. In a terminal in the new desktop session, run the following checks. To switch back, open **显示语言**, choose **English** and sign in again.

```sh
loginctl show-session "$XDG_SESSION_ID" -p Service -p Type -p Active
printf 'LANG=%s\nLANGUAGE=%s\n' "$LANG" "$LANGUAGE"
busctl --system get-property org.freedesktop.Accounts \
    "/org/freedesktop/Accounts/User$(id -u)" org.freedesktop.Accounts.User Language
cat /etc/default/locale
```

The desktop selector saves the current user's choice in AccountsService. Debian's LightDM PAM configuration rereads `/etc/default/locale` at login. The `35y700_account_language` Xsession script applies the saved language before `~/.xsessionrc` runs. A user who overrides it there can set both `LANG` and `LANGUAGE`, or set `LANG` and unset `LANGUAGE` so gettext follows `LANG`.

On 2026-11-20 the 1,112-package dev9 image with `y700-input-pinyin 0.1.0~dev3` booted via U-Boot EFI in ARM64 QEMU. After touch enrollment, LightDM authenticated the account into English Xfce session 2. A virtual touchscreen contact selected **简体中文** in the installed desktop app. The user logged out through Xfce, signed in again through Arctica, and received active X11 session 5 with `LANG=zh_CN.UTF-8` and `LANGUAGE=zh_CN:zh`. GLib returned `zh_CN`, GTK rendered its standard Cancel button as **取消(C)**, and the system locale file still specified English. The guest powered off normally. The complete root SHA-256 was `08a42daf79b0742a9d01c4e750b914d3886c60b08e5adfc51c6692ec9ef65a73`. The private receipt and screenshots are in `out/dev9-ime-language-efi-verified/`. [Repeat the two-session test](../tests/display-language/README.md)

## Verified fresh build, 2026-11-18

The third clean build completed with mmdebstrap `1.5.7-3` in 864.6645 seconds under ARM64 QEMU user emulation. Its complete installed set matched all **962 locked package/version/architecture tuples** before configuration. No historical root filesystem was copied. Configuration then completed, and all 30 repair packages plus `y700-platform 0.1.0~dev2` installed successfully, producing 993 installed packages.

The fresh integrated root passed an empty dpkg audit, APT dependency checks, ARM64 SSH configuration/effective-policy checks, persistent host-key generation, systemd unit validation and an Onboard settings round-trip. Temporary maintenance credentials were removed. Runtime APT sources contain normal signed Debian HTTPS repositories, and the clock seed was not in the future. This establishes a fresh package-base build and userspace integration only; no board boot or graphical session was exercised.

## Revalidate original metadata

With matching public apt list files and a separately trusted keyring available locally:

```sh
uv run --python 3.13 --no-project python scripts/audit-debian-inputs.py \
  --root /build/source-base --cache /build/archive-cache --output /build/audit.json
uv run --python 3.13 --no-project python scripts/verify-debian-metadata.py \
  --audit /build/audit.json --lists /build/original-apt-lists \
  --keyring /usr/share/keyrings/debian-archive-keyring.gpg --output /build/authenticated.json
uv run --python 3.13 --no-project python tests/debian-metadata.py \
  --audit /build/audit.json --lists /build/original-apt-lists \
  --keyring /usr/share/keyrings/debian-archive-keyring.gpg
```

The audit returns nonzero and lists missing/conflicting archives. The signature verifier never invents missing evidence or equates a downloaded hash with authenticity. Negative tests changed a real signed Release and a real Packages index; both were rejected. Public CI checks source and small policy/package tests, not this large original-metadata integration test or a full base rebuild.

Remaining stages: pinned kernel/toolchain/DT/initramfs, provenance-reviewed board firmware, touch-only enrollment, per-install identity finalization, filesystem/EFI assembly, update/rollback/recovery and attended hardware acceptance. Neither the historical root nor the fresh package base is a stable image release.
