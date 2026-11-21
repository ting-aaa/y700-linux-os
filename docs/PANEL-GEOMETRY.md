# Y700 internal panel dimensions

On the TB320FC_PRC, the native 1600×2560 panel reports **118 × 190 mm** through DRM. That corresponds to about 344 horizontal and 342 vertical pixels per inch using the integer millimeter values. Stock Debian Xorg reports 0 × 0 mm for this connector. The Y700 package in the installed dev12.10 system reports the panel dimensions at the graphical login.

## Evidence from the tablet

| Source | Width × height |
| --- | --- |
| Original CN350 Android device tree | Both NT36523N 144 Hz panel descriptions, including the hyper variant, specify 118 × 190 through `qcom,mdss-pan-physical-{width,height}-dimension`. The recorded boot selected base DT index 2 and overlay index 14. |
| Native Linux panel driver | The compatible `lenovo,y700-nt36523n` selects `y700_desc`. Its mode callback assigns 118 × 190 to the DRM connector's display information. |
| Real running Debian kernel | A read-only `drmModeGetConnectorCurrent()` returned 118 × 190, connected, with one mode on `card1-DSI-1`. The EDID sysfs file was empty. |
| Stock Debian Xorg | `xrandr --current` showed `DSI-1 connected primary 1600x2560 … 0mm x 0mm`. The Xorg log reported the modesetting driver and 96 DPI. The X screen's separate 423 × 677 mm entry in `xdpyinfo` comes from the default DPI calculation. |

The physical dimensions come from the stock panel descriptions and agree with the retained Linux board patch. [Pinned Asphalt display patch](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0002-asphalt-display.patch)

## Xorg correction

In Debian's `2:21.1.16-1.3+deb13u4` X server, the modesetting driver initially copies `mmWidth` and `mmHeight` from the KMS connector. Its next modes probe calls `xf86OutputSetEDID()`. That function clears both sizes and only restores dimensions it obtains from EDID. `xf86RandR12SetInfo12()` publishes the resulting values. The candidate restores the KMS pair after EDID processing for DSI connectors when both KMS dimensions are available and EDID supplied no complete pair. The existing Xfce scale setting still controls application UI size. [Debian modesetting source](https://sources.debian.org/src/xorg-server/2%3A21.1.16-1.3%2Bdeb13u4/hw/xfree86/drivers/modesetting/drmmode_display.c/) · [Xorg EDID processing](https://sources.debian.org/src/xorg-server/2%3A21.1.16-1.3%2Bdeb13u4/hw/xfree86/modes/xf86Crtc.c/) · [RandR publication](https://sources.debian.org/src/xorg-server/2%3A21.1.16-1.3%2Bdeb13u4/hw/xfree86/modes/xf86RandR12.c/) · [Candidate patch](../config/xorg/modesetting-dsi-physical-size.patch)

## Build and qualification

The source package, original tarball and Debian diff were checked against the signed trixie-security Sources index. The retained 2026-11-19 InRelease has SHA-256 `04b0a435801d3b6798c397526d528892183080ebadec7d39b95e6df671441da4`. Its signed `main/source/Sources.xz` has SHA-256 `f66a707b8abd87b9c57f17380b65db82fd263689c04f4b789294798a8c03588f`. The selected package is `xorg-server 2:21.1.16-1.3+deb13u4`. [Source archive checksums](../config/xorg/debian-source.sha256) · [Debian source package](https://security.debian.org/debian-security/pool/updates/main/x/xorg-server/xorg-server_21.1.16-1.3+deb13u4.dsc)

On a Debian 13 ARM64 build host, put the three pinned source files under `$sources`. From the repository, install the upstream build dependencies and run the Debian package recipe. It adds the panel fix to Debian's quilt series and preserves the X server's package layout. The output pair is `xserver-xorg-core` (arm64) and `xserver-common` (all), version `2:21.1.16-1.3+deb13u4+y7001`. Debian's core package requires a common package at least as new as its source version. [Package builder](../scripts/build-xorg-dsi.sh)

```sh
lock="$PWD/config/xorg/debian-source.sha256"
(cd "$sources" && sha256sum --strict --check "$lock")
sudo apt-get build-dep "$sources/xorg-server_21.1.16-1.3+deb13u4.dsc"
mkdir -p "$out"
DEB_BUILD_OPTIONS='parallel=4 nocheck noddebs' bash scripts/build-xorg-dsi.sh "$sources" "$out"
```

The earlier module-only comparison used a Meson build on ARM64. Set `product` to the product repository's absolute path and run the following commands in the Debian-patched source tree.

```sh
git apply --check "$product/config/xorg/modesetting-dsi-physical-size.patch"
git apply "$product/config/xorg/modesetting-dsi-physical-size.patch"
uv run --offline --no-project --python /usr/bin/python3 python /usr/bin/meson setup \
    --wrap-mode=nodownload --prefix=/usr -Dxorg=true -Dxvfb=false -Dxnest=false \
    -Dxephyr=false -Dglamor=true -Ddri1=false -Ddri2=true -Ddri3=true \
    -Dglx=true -Ddocs=false -Ddevel-docs=false -Dsystemd_logind=true build-panel
ninja -C build-panel hw/xfree86/drivers/modesetting/modesetting_drv.so
```

In a networkless ARM64 guest, stock Debian Xorg loaded either its installed driver or the built AArch64 module through an isolated module search path. A virtual KMS connector in the Y700 kernel supplied controlled dimensions and optional EDID. Three consecutive RandR queries per case exercised the initial mode query and subsequent probes.

| Driver | Virtual connector | Geometry supplied by KMS | EDID geometry | RandR output |
| --- | --- | --- | --- | --- |
| Stock | DSI | 118 × 190 | Absent | 0 × 0 |
| Candidate | DSI | 118 × 190 | Absent | 118 × 190 |
| Candidate | Virtual | 118 × 190 | Absent | 0 × 0 |
| Candidate | DSI | 0 × 190 | Absent | 0 × 0 |
| Candidate | DSI | 118 × 190 | 300 × 200 | 300 × 200 |

The tested module is in the private build output `out/xorg-dsi-geometry/modesetting_drv.so`, SHA-256 `714d119c89d58d8cf0c1de05fdeea2bcbb13b9c507e44005574fe4dd0cc4e154`. The nearby receipt contains the guest transcript and the real tablet's reduced KMS and Xorg observations. Physical acceptance requires a session using the candidate Xorg module. The existing kernel already exports the panel dimensions. [Debian source package](https://security.debian.org/debian-security/pool/updates/main/x/xorg-server/xorg-server_21.1.16-1.3+deb13u4.dsc)

## Debian package test, 2026-11-20

A full ARM64 Debian package build produced the core and common packages above. The archived build used the earlier patch context. Applying the checked-in patch with zero fuzz produced the same compiled input, `drmmode_display.c` SHA-256 `3d52150e8a487c927db22b1746ebf174823a7759151fa1d643c5134353056755`. Compared with their authenticated Trixie counterparts, both packages have the same installed paths under `/usr`. The X server's 2,005 exported dynamic symbol/type pairs, the driver's two exported pairs and both binaries' direct library dependencies matched stock. The packaged driver has SHA-256 `8db0cd0e45540948fd847b601e85f1c71647461a992869f0f653d48121f206e4`. [Tested archive checksums](../config/xorg/arm64-packages.sha256)

A networkless ARM64 QEMU guest first reproduced the stock 0 × 0 result. It installed both packages with dpkg into a disposable RAM overlay, passed `dpkg --audit`, `dpkg -V` and `apt-get check`, and loaded `/usr/lib/xorg/modules/drivers/modesetting_drv.so` from Xorg's default module path. All 15 RandR queries across the five cases in the table matched, including the EDID-free DSI panel at 118 × 190 mm and the EDID override at 300 × 200 mm. The guest powered off with test exit 0. The two archives, package audit, build information and serial receipt are in `out/xorg-dsi-packages/`. The installed packages have also been checked on the physical DSI panel below. [Repeat the package test](../tests/xorg-dsi/README.md)

## Installed dev12.10 graphical login

On 2026-11-21 the TB320FC_PRC booted the permanent dev12.10 entry into LightDM. Both Xorg packages were `2:21.1.16-1.3+deb13u4+y7001`. The server listening on display `:0` mapped the expected modesetting driver. Its open file's device number, inode and SHA-256 matched the running executable mapping and the packaged driver.

The connected `card1-DSI-1` returned zero EDID bytes. Three consecutive queries to the same X server returned **118 × 190 mm**, **1600 × 2560 at 120 Hz**, in normal portrait orientation. The greeter’s Onboard keyboard ran with `GDK_SCALE=2`. The NT36523N input node carried the udev touchscreen tag, and its XInput transformation was the identity matrix for this orientation. These readings establish the panel metadata and configured input mapping at login. Physical finger placement was not measured in this run. [Read-only board check](../tests/xorg-dsi/board.sh)
