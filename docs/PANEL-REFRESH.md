# Y700 国行内屏的 60 Hz 候选模式

dev12.11 的 NT36523N 驱动原先只发布 1600 × 2560、120 Hz。候选内核保留该模式的全部字段和首选位置，增加同分辨率的 60 Hz。PC 已验证原厂时序、两次独立构建、完整系统启动和限次启动回退。本节记录 PC 侧证据，实机刷新率应使用 DRM vblank 时间戳测量。[已装显示系统](PANEL-GEOMETRY.md) · [候选补丁](../config/kernel/nt36523n-y700-60hz.patch)

## 原厂模式与切换

TB320FC_CN_OPEN_USER 的 CN350 DTBO 第 14 项，在 `/fragment@52/__overlay__` 定义了 NT36523N TCL 视频面板。原厂 Android 的启动参数选择了同名普通面板，运行时节点位于 `/soc/qcom,mdss_mdp@ae00000/qcom,mdss_dsi_nt36523n_fhd_plus_cphy_144hz_vid`。两个来源含有相同的基础时序、双 C-PHY、DSC、120 Hz 基准和 144、120、60、30 Hz 的动态刷新率表。项目只发布此次计算和检查过的 60 Hz。[工厂及运行时设备树核对](../tests/panel-refresh/check-cn350.py) · [联想产品规格](https://psrefstuff.lenovo.com/syspool/Sys/PDF/datasheet/Final%20Lenovo%20Legion%20Tab%20Datasheet.pdf)

CN350 的 ARM64 `msm_drm.ko` SHA-256 为 `c1a04521c8f45bed92a85c100b2a1ec47d8db5461af368760444601ba2226492`。在模块的 `.text` 中，`dsi_display_get_modes` 于 `0x15186c` 比较目标帧率与 144，选择水平前沿分支 3 或垂直前沿分支 4。`dsi_display_get_dfps_timing` 在垂直分支将刷新率、行总数和原垂直前沿交给 `dsi_display_dfps_calc_front_porch`。120 降到 60 时，其结果为 `30 + 2850 × (120 − 60) / 60 = 2880` 行。144 Hz 另有水平前沿的取整处理。[高通 DFPS 参考实现](https://android.googlesource.com/kernel/msm/+/8087b7545015a42060fbf0a84e497d24f38c4359/drivers/gpu/drm/msm/dsi-staging/dsi_display.c)

选中节点只有一组上电时序，没有独立的 60 Hz DCS 切换指令集。`dsi_panel_match_fps_pen_setting` 对 60 和 120 选择相同的非 144 Hz 笔控设置。Linux 驱动沿用的 459 条上电指令已设置 page 0x10 的 B2=0x91、B3=0x01，与该节点的 `others-enable-control`、`others-switch` 相符。候选保留原有上电、断电、DSC 和触控流程。通过 RandR 改变刷新率会走 DRM 完整的模式设置；相同的 120 Hz 时序通过 DRM 的模式相等判断，无需因新增的模式行重新设置。切换期间的屏幕闪烁和触控行为需在硬件测量。[当前驱动的社区来源](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0002-asphalt-display.patch)

| 模式 | DRM 像素时钟 | 水平总长 | 垂直前沿 / 脉冲 / 后沿 | 垂直总长 | 计算刷新率 |
| --- | --- | --- | --- | --- | --- |
| 首选 | 691.524 MHz | 2022 | 30 / 4 / 256 | 2850 | 120.000 Hz |
| 新增 | 691.524 MHz | 2022 | 2880 / 4 / 256 | 5700 | 60.000 Hz |

每条链路传输的 800 个像素经 8 bpp DSC 折算为 267 个 RGB888 时钟；每链路的水平前沿、脉宽和后沿分别是 137、20、54。两种模式的每链路总长均为 478，Linux MSM 计算的像素时钟为 163.476 MHz，三通道 C-PHY 的 16 位传输时钟请求为 81.738 MHz。因此切换只需改变每帧的行数。DSI `TOTAL.V_TOTAL` 是 16 位，写入的 5699 在范围内。垂直有效窗口仍从 260 到 2820。DPU 的 VSYNC 周期为 32 位，即使使用未经双链路拆分的上界 `5700 × 2022` 也能表示。这些数值来自驱动计算，不代表实测时钟或功耗。

## 构建与启动验证

```sh
UV_BIN=/path/to/uv bash scripts/build-camera-ldo5.sh --lens --panel-60 "$prepared_kernel" "$new_output"
bash scripts/build-dt-probe-entry.sh --panel60 "$dev1211_permanent_entry" "$new_output" "$new_entry"
```

构建器在私有挂载命名空间应用补丁。两次独立链接生成逐字节相同的 ARM64 EFI 内核、设备树和 notes。检查器从 `vmlinux` 的 `y700_modes` 读取真实时序，比对原 120 Hz 对象的全部 120 个字节，并在 EFI Image 内逐字节定位两条模式。内核版本、导出符号和模块兼容性检查沿用 dev12.11 构建流程。设备树与该版本使用的 GT9768 + PMK8350 RTC1 设备树完全相同。[构建器](../scripts/build-camera-ldo5.sh) · [内核二进制模式检查](../tests/panel-refresh/check-kernel.py)

| 产物 | SHA-256 |
| --- | --- |
| kernel.efi | `0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60` |
| board.dtb | `53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7` |
| notes | `c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063` |
| 原 dev12.11 initrd | `864f3630b666f7332027a7187d48be7afa5f0d537eef95ea04764d9edf836e96` |
| 独立入口清单 | `1f208f3a5f4713a69987e62820d811d7886e801f7931ece5cfb4780cda7e4223` |

一次完整 U-Boot → systemd-boot → Debian ARM64 启动验证了新内核 notes 和原 dev12.11 根的 1,240 个软件包。另一组独立的真实 EFI 启动使用正式 initrd 加小型观察器，第一次选中限次内核、消耗唯一计数，第二次返回原 dev12.11 内核并验证两次的不同 notes。QEMU 使用 virt 设备树。真实 FAT 事务还逐个篡改载荷以验证拒绝路径，检查原菜单在恢复后完全一致。记录保存在本地 `out/panel-refresh-60/`。[限次菜单与恢复测试](../tests/installed-trial/panel60-arm.sh)

板端包中的 `board-entry.sh arm entry RUN_ID` 在正式 dev12.11 上安装独立条目并武装一次尝试，重启由操作者发起。系统沿用原文件根和原 initrd，启动原有 4 分钟回退定时器。`--panel60 confirm` 保留定时器，控制器拒绝晋升。回到原内核后，`board-entry.sh restore entry RUN_ID` 恢复原默认配置并移除此次测试文件。定时器依赖内核和 systemd 继续运行。若设备在更早阶段失去响应，下次复位由已消耗的固件计数选择原内核。[板端事务入口](../tests/panel-refresh/board-entry.sh)
