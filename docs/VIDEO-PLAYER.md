# Optional Xfce video player for dev12.8

The optional Parole layer gives Xfce a desktop application for local MP4 and WebM files. The sealed dev12.8 desktop has no default handler for either type. The Debian Parole desktop entry advertises both and opens filenames with `parole %F`. Its dependencies include GStreamer's X11 sinks and software decoders. This layer also installs the AVC and HEVC parsers for ordinary MP4 packet framing. [Original desktop behavior](VIDEO-CODEC-USERSPACE.md) · [Debian Parole package](https://packages.debian.org/trixie/parole)

| Offline archive | Value |
| --- | --- |
| File | `out/video-player/y700-dev12.8-parole-arm64.tar.gz` |
| Size and SHA-256 | 74,018,105 bytes, `db0dd4a1dbdeb046bab824683c1e085734c743c17f7f2a64b7aee79282312a66` |
| Sealed parent | 1,124 installed package tuples, SHA-256 `a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84` |
| With player | 1,240 tuples, SHA-256 `89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d` |
| Debian transaction | 116 added, zero upgraded or removed. Archives total 73,977,628 bytes. Installed-Size totals 229.14 MiB |

The primary packages are Parole 4.18.2-1, `gstreamer1.0-x` and `gstreamer1.0-libav` 1.26.2-1+deb13u1, and `gstreamer1.0-plugins-bad` 1.26.2-3+deb13u3. The Debian package name “bad” is GStreamer's collection name for the set that includes `h264parse` and `h265parse`. Parole 4.18.2 creates `playbin`. Its default `/video/videosink` string is `autoimagesink` and it falls back to `ximagesink` if that factory is unavailable. The supplied packages use their standard desktop associations and decoder selection. [Parole source shipped by Debian](https://deb.debian.org/debian/pool/main/p/parole/parole_4.18.2.orig.tar.bz2) · [H.264 parser](https://gstreamer.freedesktop.org/documentation/videoparsersbad/h264parse.html)

## Verified desktop behavior

In a native ARM64 QEMU guest, the ordinary account ran Xfce settings and Xfwm on a 2560 × 1600 Xorg screen at GTK scale factor 2. After installation, GIO returned `org.xfce.Parole.desktop` for both file types without a per-user MIME override. Six launches produced six distinct Parole processes.

| Local file | Desktop `gio open` | Select file in Thunar and press Return |
| --- | --- | --- |
| H.264 Baseline / MP4 | All three color pairs displayed | All three displayed |
| HEVC Main / MP4 | All three displayed | All three displayed |
| VP9 / WebM | All three displayed | All three displayed |

The probe verified the exact filename in each Parole process and observed changing pixels on the Xorg screen. The Thunar case selected the clip in its own folder, verified X11 focus on that particular window and activated the file with Return. This isolates it from any earlier folder window. The guest exercised software playback of silent clips. Physical Iris selection and frame accuracy have a separate board receipt. [Thunar's file-selection behavior](https://manpages.debian.org/trixie/thunar/thunar.1.en.html) · [Physical decoder checks](VIDEO-CODEC-BOARD.md)

The repeat installation check accepted the completed 1,240-package set, and the guest powered off after `VIDEO_USERSPACE_EXIT=0`. The reduced local receipt `out/video-player/qemu-dev12.8.log` has SHA-256 `f67bba9ceddd3f8256834233f3702a1bf87c103d029c1b4681dabdce9267a739`. The builder also rejected an altered archive before publishing output, and the lock generator rejected a different base package set.

## Build or apply the archive

On Linux, run the following in the project checkout. The builder downloads missing Debian archives, verifies all 116 sizes and SHA-256 values and creates a new output file. Rebuilding from the local cache requires only the Python standard library and uv. Two independent builds produced the hash above. [Archive builder](../tests/video-player/bundle.py) · [Pinned package and archive identities](../tests/video-player/debian.lock.json)

```sh
mkdir -p out/video-player
uv run --offline --no-project --python /usr/bin/python3 python \
    tests/video-player/bundle.py --fetch out/video-player/archives \
    out/video-player/y700-dev12.8-parole-arm64.tar.gz
```

The installer supports a local package check from an ordinary account. Apply the layer as root inside a writable ARM64 dev12.8 image build environment. The installer checks the complete base package digest, simulates the local-only transaction, installs the packages, restores dependency auto-marking and verifies the final digest and dpkg status. It accepts a repeat run on the exact completed package set. Existing user-selected MIME associations follow the normal GIO precedence. [Installer](../tests/video-player/install.sh)

```sh
tar -xzf y700-dev12.8-parole-arm64.tar.gz
bash y700-video-player/install.sh --check
sudo bash y700-video-player/install.sh --install
```

## Reproduce the checks

The lock was derived from the real dev12.8 dpkg status and the arm64 main Packages index authenticated by the September 12, 2026 Debian trixie InRelease. The independently downloaded archived InRelease had the same SHA-256 as the retained copy, `0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675`. The keyring digest, signed-index digest, historical date and individual archive hashes are in the lock. [Debian signed snapshot](https://snapshot.debian.org/archive/debian/20260913T000000Z/dists/trixie/InRelease) · [Lock regeneration](../tests/video-player/make-lock.py)

```sh
uv run --offline --no-project --python /usr/bin/python3 python \
    tests/video-player/make-lock.py "$DEV12_8_DPKG_STATUS" "$SIGNED_ARM64_APT_LISTS" \
    /usr/share/keyrings/debian-archive-keyring.gpg /tmp/parole-regenerated.lock.json
cmp tests/video-player/debian.lock.json /tmp/parole-regenerated.lock.json
```

To run the application test, first generate the three silent clips documented in the [baseline test](VIDEO-CODEC-USERSPACE.md). Repeat their packets to give the ordinary application time to open and show several frames under CPU emulation. The shared runner attaches the sealed root read-only, installs the archive into a temporary overlay in the ARM64 guest and launches an ordinary-user Xfce settings session with an Xorg virtual screen. The guest has no network interface other than loopback and no codec device. [Clip preparation](../tests/video-player/extend-clips.py) · [QEMU runner](../tests/video-userspace/run-qemu.sh) · [Desktop pixel probe](../tests/video-player/check-x11.py)

```sh
uv run --no-project --with imageio-ffmpeg==0.6.0 python \
    tests/video-player/extend-clips.py out/video-userspace/new-clips out/video-player/new-clips
bash tests/video-userspace/run-qemu.sh "$DEV12_8_ROOT_EXT4" "$KERNEL" \
    "$ARM64_BUSYBOX" "$ARM64_UV" "$ARM64_XORG_DUMMY_DEB" \
    out/video-player/new-clips --player out/video-player/y700-dev12.8-parole-arm64.tar.gz
```

For the 1920 × 1080 desktop fixtures, pass `--full-hd` to `tests/video-userspace/make-clips.py` and supply its output to `extend-clips.py`. The three files in `out/video-player/full-hd/` each contain 48 frames over 24 seconds. Host software decoding verified both color panels on every frame of every file. Their SHA-256 values are in `out/video-player/full-hd-verification.log`. The six source NV12 frames have a 1920-byte stride and 1088 luma storage rows.
