# Y700 国行内屏的 60 Hz 候选模式

dev12.11 的常用内核发布 1600 × 2560、120 Hz。双刷新率内核沿用这一首选模式，增加同分辨率的 60 Hz。2026-11-21，国行实机在点亮的内屏上完成两轮 120 → 60 → 120 Hz 切换。以下数据取自显示控制器的垂直消隐中断。[已装显示系统](PANEL-GEOMETRY.md) · [驱动补丁](../config/kernel/nt36523n-y700-60hz.patch)

## 国行实机

第一次限次启动进入 LightDM。Xorg 在 DSI-1 上列出 120 和 60 Hz，并在开机约 240.7 秒后正常退出。恢复后通过 USB 取回了前一次启动的 Xorg 和登录界面记录。本次没有记录帧时间戳。

第二次限次启动让平板自行采样。每个阶段读取三组 DRM vblank 序号与内核时间戳，每组取 16 个时间点，相邻时间点之间共 15 个刷新周期。每组采样前各自核对了内屏连接、亮屏状态、当前 RandR 模式和正在使用内屏的登录界面。

| 顺序 | 设定刷新率 | 15 个周期的总用时 | 实测刷新率 |
| --- | --- | --- | --- |
| 启动 | 120 Hz | 124,999–125,001 µs | 119.999–120.001 Hz |
| 第一次降到 60 | 60 Hz | 249,999–250,001 µs | 60.000 Hz |
| 第一次回到 120 | 120 Hz | 124,999–125,002 µs | 119.998–120.001 Hz |
| 第二次降到 60 | 60 Hz | 250,000–250,001 µs | 60.000 Hz |
| 第二次回到 120 | 120 Hz | 124,999–125,001 µs | 119.999–120.001 Hz |

切换期间的内核日志通过 DSI、DPU、CRTC、vblank 错误检查。约第 19 秒，平板记录到图形登录、USB 维护网络、SSH 和回退计时器均就绪。两次启动都自动返回原 dev12.11 内核。每次移除试验菜单后，外层 EFI 的同一组 32 个文件与试验前逐项相同，清单排除会按次更新的随机种子。第二次回退还核对了机内保存的原始采样与 USB 取回的副本。原始记录在 `out/panel-refresh-60/physical/`，其 `RECEIPTS.sha256` 的 SHA-256 为 `8b05847b0ffd75cd028dda3e6c6ab65365a7cc5cd4dfc5877e4f2c2c710bead7`。持续负载、切换瞬间的闪烁、光学测量、两档的功耗差另行验证。[实机测量程序](../tests/panel-refresh/board-scanout.sh) · [vblank 读数](../tests/dpu-vblank.c)

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

### 从电脑打包，在平板私有目录解包

早期 `board.tar` 的根目录成员 `./` 带有 Windows 挂载映射的 0777 权限。以 root 解包时，这个成员会放宽接收目录的权限。新版 `board-private.tar` 只收录具名的子目录和文件，目录与脚本为 0700，数据及清单为 0600，所有成员的 UID/GID 为 0。回归测试分别从实际 DrvFS 输入与全树 0777 的副本打包，比较整包字节，并用 root 默认解包核对接收目录和全部成员的权限。[打包脚本](../tests/panel-refresh/package-board.sh) · [权限回归](../tests/panel-refresh/check-board-package.sh)

```bash
# 电脑上的 Linux 或 WSL，新归档路径须空闲。
bash tests/panel-refresh/package-board.sh "$new_entry" "$new_tar"
bash tests/panel-refresh/check-board-package.sh "$new_entry"
```

将归档传入平板后，在 root 的 Bash 中把 `archive` 设置为收到的绝对路径。以下命令校验本次归档，在私有临时目录里解包并逐文件核验。后续从打印的目录运行本轮的 `board-entry.sh`。

```bash
set -euo pipefail
umask 077
: "${archive:?请先设置收到的 board-private.tar 绝对路径}"
[[ $EUID == 0 && $archive == /* ]]
printf '%s  %s\n' 80c5e0a9ecf9dd6c81ab6fe21ea6fb36c54e922567585882025f78f8fc71ee96 "$archive" | sha256sum --strict -c -
stage=$(mktemp -d /var/tmp/y700-panel-entry.XXXXXXXX)
tar --no-same-owner --no-same-permissions -xf "$archive" -C "$stage"
[[ $(stat -c '%u:%g:%a' "$stage") == 0:0:700 && -z $(find "$stage" -perm /077 -print -quit) ]]
(cd "$stage"; sha256sum --strict -c SHA256SUMS; cd entry; sha256sum --strict -c SHA256SUMS)
printf '入口目录 %s\n' "$stage"
```

观察器把检查结果写入另一个已准备好的 root 私有目录 `/var/tmp/y700-panel60-run-a`。它以服务身份读取 `/run/lightdm/root/:0` 并连接本机 X11 套接字，使用 `journalctl -k` 游标检查本轮内核信息。PC 已在相同的 systemd 沙箱选项下通过独立 Xvfb 的认证、RandR 修改及回读、无凭据拒绝、内核日志读取和目录写权限测试。安装与移除观察器由服务外的管理脚本执行。[观察器](../tests/panel-refresh/local-observer.sh) · [服务配置](../tests/panel-refresh/manage-local-observer.sh) · [systemd 文件系统沙箱说明](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectSystem=)
