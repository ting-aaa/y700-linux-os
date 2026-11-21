# Parole HiDPI playback controls

This optional Debian arm64 rebuild gives the playback slider and six buttons in Parole 4.18.2 a minimum height of 48 logical pixels when GTK reports a scale factor of 2 or higher. The buttons also receive a 48-pixel minimum width. Parole reapplies the request when the scale changes and restores the original natural size at 1×. A larger size supplied by the user's theme still takes precedence. The patch acts on GTK's named widgets in Parole's playback row. [Debian Parole source](https://sources.debian.org/src/parole/4.18.2-1/src/parole-player.c/) · [GTK size requests](https://docs.gtk.org/gtk3/method.Widget.set_size_request.html)

## Build and try

The source hashes come from Debian trixie's signed main Sources index. On arm64 Debian trixie with Parole's build dependencies, download the three named files into a new directory and build the candidate. [Debian Parole source archives](https://deb.debian.org/debian/pool/main/p/parole/)

```sh
mkdir sources
awk '{print $2}' packaging/parole-touch/sources.sha256 | while read -r name; do
    curl -fSL "https://deb.debian.org/debian/pool/main/p/parole/$name" -o "sources/$name" || exit 1
done
bash packaging/parole-touch/build.sh sources out/parole-touch
```

The candidate and Debian rollback package have the same binary package name. Close Parole before changing versions and reopen a video through the usual desktop entry for each comparison. The dev12.9 local launcher continues to select its private Iris plugin. The stock package inside the official local player bundle has SHA-256 `2ba9a27f1e68eda4fbb521a0f4e9db486ea25b801fbfa2d8b3d2a4d36fb3a995`.

The locally tested candidate `out/parole-touch/parole_4.18.2-1+y7001_arm64.deb` is 358,604 bytes with SHA-256 `2ca6a96bed49fe03cb0c577c7b08b135a3fad38535878a112c999a456b8f6565`. Its package dependencies match Debian's original archive.

```sh
sudo apt install ./parole_4.18.2-1+y7001_arm64.deb
sudo apt install --allow-downgrades ./parole_4.18.2-1_arm64.deb
```

## PC regression

Run the test from the checkout on Linux with ARM64 execution or qemu-user binfmt. It verifies the generic dev12.9 root hash, mounts it read-only and installs the candidate and rollback packages into a disposable writable overlay. An ordinary private Xfce session opens the generated seek clip using GIO, measures the mapped widgets through AT-SPI and uses the X11 pointer to pause and resume. The test compares the 1× geometry and the File menu in both scales before restoring the complete original package inventory. [Seek clip generator](../../tests/video-codec/seek-clips.py) · [Overlay regression](../../tests/parole-touch/overlay.sh)

```sh
sudo bash tests/parole-touch/overlay.sh "$DEV12_9_ROOT" "$CANDIDATE_DEB" "$STOCK_DEB" \
    "$ARM64_XVFB" "$ARM64_UV" out/video-seek/clips/h264.mp4
```

| Desktop scale | Debian play/pause | Candidate play/pause | Debian seek slider | Candidate seek slider |
| --- | --- | --- | --- | --- |
| 100% | 36 × 34 px | 36 × 34 px | 426 × 34 px | 426 × 34 px |
| 200% | 72 × 68 px | 96 × 96 px | 852 × 68 px | 708 × 96 px |

The six wider buttons used 144 pixels of horizontal space at 200%. The File menu measured 54 × 27 logical pixels throughout. A separate 200% run selected HighContrast through Xfce and produced the same control sizes and working pause/resume. Set `Y700_PAROLE_TEST_THEME=HighContrast` in the overlay runner's environment to exercise that preference. Local receipts are `out/parole-touch/geometry.log` and `out/parole-touch/highcontrast-2x.log`.

## Seek on release at HiDPI

Revision `4.18.2-1+y7002` keeps the 48-logical-pixel playback controls. During a primary pointer or touch drag at 2×, GTK updates the thumb and elapsed-time label. Releasing commits the displayed position through Parole's existing whole-second, key-unit GStreamer seek. A cancelled touch, broken grab, stopped stream or unmapped slider clears the preview. Keyboard and accessibility value changes outside a drag still seek immediately. At 1× the slider retains Debian's continuous seeking.

Build using the same pinned Debian sources. Close Parole and reopen the file after installing or restoring the package. The original y7001 builder and all three Debian source digests remain available above.

The arm64 `parole_4.18.2-1+y7002_arm64.deb` is 359,232 bytes with SHA-256 `f49b70eece107e02a69c67dee445500a182cfe19138e76bf7ed8e18e3eee1968`.

```sh
bash packaging/parole-touch/seek/build.sh sources out/parole-touch-y7002
sudo env Y700_PAROLE_TEST_SCRUB=1 bash tests/parole-touch/overlay.sh "$DEV12_9_ROOT" \
    out/parole-touch-y7002/parole_4.18.2-1+y7002_arm64.deb "$STOCK_DEB" \
    "$ARM64_XVFB" "$ARM64_UV" out/video-seek/clips/h264.mp4
```

The optional test sends X11 pointer presses, motion and releases to the mapped GTK window. While dragging, it reads the accessible thumb, elapsed label and paused video pixels. It counts actual TIME seek events in GStreamer and checks the displayed colour after release. The clip has a keyframe each second and a different colour every four seconds. The same test checks a single click, a focused Right key, an accessibility value change, and resumed playback. The PC run uses software video decoding.
