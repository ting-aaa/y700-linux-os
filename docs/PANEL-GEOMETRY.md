# Y700 internal panel dimensions

On the TB320FC_PRC, the native 1600×2560 panel reports **118 × 190 mm** through DRM. That corresponds to about 344 horizontal and 342 vertical pixels per inch using the integer millimeter values. The installed Debian Xorg modesetting driver loses both dimensions before it exports the connector to RandR.

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

The source package, original tarball and Debian diff were checked against the signed trixie-security Sources index. The patch passed a clean application to the Debian-patched source. On an ARM64 Debian 13 build root with the X server build dependencies, use the following commands from that source tree. Set `product` to the product repository's absolute path.

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
