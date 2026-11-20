# Optional Iris playback in Xfce

Opening a local video from Thunar can use the Y700's Iris decoder through Parole. This dev12.8 add-on combines the authenticated Debian player layer with the board-specific GStreamer plugin that handles the VP9 first picture and partially specified BT.601 input. The physical tablet trial opened H.264, HEVC and VP9 through the normal file manager. [Debian player layer](VIDEO-PLAYER.md) · [Driver and codec evidence](VIDEO-CODEC-BOARD.md) · [Plugin changes](VIDEO-VP9.md)

| Archive identity | Value |
| --- | --- |
| Local file | `out/video-player-integration/y700-dev12.8-parole-iris-arm64.tar.gz` |
| Size and SHA-256 | 77,257,181 bytes, `0abe5888335940419fe49d7ca2e03ca17a5f767aeb6b10d2c01de5b34081e64f` |
| Original Debian player archive inside | `db0dd4a1dbdeb046bab824683c1e085734c743c17f7f2a64b7aee79282312a66` |
| Board plugin | `7c3e57f206c81fa0af09a3cf34d9836a686527212c7738dc4657d6c315ec9962` |
| Supported image package sets | 1,124 sealed dev12.8 packages or the same image with the 116 Debian player additions |

## Install on a writable dev12.8 image

Extract the archive and run the installer **inside the target image**. The component hashes and package identity are checked before installation. An existing, different local launcher, plugin or desktop entry at the managed paths stops the transaction. `--verify` checks the installed integration, the original system plugin and Debian's desktop entry.

```sh
tar -xzf y700-dev12.8-parole-iris-arm64.tar.gz
bash y700-parole-iris/install.sh --check
sudo bash y700-parole-iris/install.sh --install
bash y700-parole-iris/install.sh --verify
```

The add-on installs a local copy of Debian's translated `org.xfce.Parole.desktop` under `/usr/local/share/applications`. Its Open, Play, Previous and Next commands use `/usr/local/bin/y700-parole`. The same desktop ID preserves the normal GIO associations and the priority of a user's choice of a different player. A fresh Parole launched through that entry prepends `/usr/local/lib/y700-parole/gstreamer-1.0` to its plugin search path and uses a separate registry below the user's cache directory, `y700-parole/registry.aarch64-iris-r2.bin`. Other GStreamer programs retain their Debian plugin and registry. Parole normally reuses a running instance. Close any Parole session started before installation and reopen the movie to start the integrated player. [Launcher](../tests/video-player-integration/y700-parole) · [Installer](../tests/video-player-integration/install.sh)

## Physical desktop evidence

In tablet trial 12, the ordinary account opened three 1920 × 1080 silent files from Thunar in a private 200% Xfce display. The harness sampled all three expected color pairs from each window, checked the exact file argument, and matched the decoder's data to that Parole PID. Each process mapped the installed local plugin and had its own player registry setting. The desktop session used its normal GStreamer environment.

| File | Decoder selected by Parole | Observed decoded buffers |
| --- | --- | --- |
| H.264 / MP4 | `v4l2h264dec` | 10 |
| HEVC / MP4 | `v4l2h265dec` | 10 |
| VP9 / WebM | `v4l2vp9dec` | 10, including the confirmed first keyframe |

The integrated image ran in tmpfs on the physical tablet. The codec returned to runtime suspend, the original boot and seat stayed active, and the final check found zero leaked mounts or loop devices. The observed buffers cover the playback interval sampled by this test. The physical receipt `out/iris-physical/parole-thunar-12.log` has SHA-256 `048b4f3e88219c2cb988433ab74f400ac3beeb0601ca6a5405d085a4b8fbe856`. [Physical test and scope](VIDEO-CODEC-BOARD.md)

## Check a disposable image

The Linux PC test mounts the sealed ext4 read-only and performs two installs in a writable overlay. It checks that a conflicting local file stops preflight, that the repeat install preserves the launcher inode and modification time, and that both Debian-owned files retain their original hashes. The ordinary X11 user opens a generated MP4 through GIO. The probe reads that Parole process's arguments and environment and checks the resolved plugin filename using the same private registry. Running the same query in the ordinary desktop environment resolves the original Debian plugin. [Overlay test](../tests/video-player-integration/test-overlay.sh) · [GIO and registry check](../tests/video-player-integration/check-session.py)

The reference run finished with `INTEGRATED_PLAYER_PASS`. The reduced receipt `out/video-player-integration/verification.log` has SHA-256 `e834c4625f088fef83732f6f13a803928c91c8cdb0385be1f3d9b9296f7f11c5`.

```sh
sudo bash tests/video-player-integration/test-overlay.sh "$DEV12_8_ROOT_EXT4" "$COMBINED_ARCHIVE" \
    "$ARM64_XVFB" "$ARM64_UV" "$ARM64_GSTREAMER_TOOLS_DEB" "$SILENT_MP4_FIXTURE"
```

## Rebuild

On a Linux host, supply the original player archive, the separately built plugin, and the directory containing the four pinned Debian source archives. Two builds of the combined archive matched byte for byte. The builder extracts the desktop entry from the original Debian Parole package and updates its executable fields. It packages the original Debian source tarballs and signature, both local patches and headers, the build scripts, and the relevant copyright and license notices. `source/build-color.sh` in the archive rebuilds the modified plugin with the appropriate ARM64 development environment. [Plugin build](../tests/video-vp9/build-color.sh) · [Archive builder](../tests/video-player-integration/build.sh) · [Attribution](../tests/video-player-integration/NOTICE)

```sh
bash tests/video-player-integration/build.sh \
    out/video-player/y700-dev12.8-parole-arm64.tar.gz \
    out/iris-input-color-r2/private/libgstvideo4linux2.so "$DEBIAN_SOURCE_ARCHIVES" \
    out/video-player-integration/y700-dev12.8-parole-iris-arm64.tar.gz
```
