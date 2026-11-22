# Y700 二代 Debian dev13.0 完整硬件镜像

本镜像面向国行联想拯救者 Y700 二代（`TB320FC_PRC` / `SM8475` / Adreno 730），基于 Debian 13 ARM64 + Xfce 触屏桌面，整合了经过实机硬件验证的统一内核、设备树、15 个驱动模块、AudioReach 采集拓扑与修复冷启动探测的 ALSA UCM2 配置。

## 本版新增与完整硬件覆盖

- **显示与 GPU**：60 Hz / 120 Hz 双刷新率内屏切换、KTZ8866 背光、Adreno 730 Mesa Freedreno 4.6 + Turnip Vulkan + GMU HFI 队列投票修复。
- **触控**：NT36523N 十点电容触控（16000×25600），随刷新率与旋转自动保持坐标映射。
- **无线网络与蓝牙**：WCN6855 `ath11k` 双频 Wi-Fi（含 WPA3 与 5 GHz / 2.4 GHz 漫游）与 `hci0` 蓝牙（支持每台设备独立的出厂蓝牙地址注入）。
- **扬声器与内置双麦克风**：双 CS35L45 保护 DSP 扬声器 + WCD9385 SoundWire 双模拟麦克风（`AMIC1` + `AMIC4`）。本版修复了 ASoC `"sleep"` pinctrl 导致 WCD9385 硬复位的问题、TX SoundWire 时钟分频时序，以及 PipeWire/WirePlumber 冷启动探测 `HiFi` 配置时因 `MultiMedia3` 混音器未提前打开而回退至 Dummy Output 的问题，开机即用扬声器与麦克风全双工音频。
- **双线性震动马达**：左右双路 `AW86927`（`y700-haptic-left` / `y700-haptic-right`），内置匹配 Y700 X 轴线性马达谐振频率的 170.2 Hz SRAM 波形（141 采样点，8000 mV 保守升压）。
- **三摄模组、自动对焦与后置闪光灯**：`hi1339`（13MP 后置主摄 + `gt9768` 出厂标定 360–605 步进对焦马达）、`s5k4h7`（8MP 前摄）、`sc202cs`（2MP 微距）以及 PM8350C 双通道 `white:flash` 后置闪光灯/手电筒。
- **全套传感器与电源管理**：SLPI SSC 七通道传感器（加速度计、陀螺仪、磁力计、环境光、距离、指南针融合、BU52053NVX 霍尔传感器）、`iio-sensor-proxy` 自动旋转与亮度、电池/双 USB-C UCSI 以及 `PMK8350` 唤醒 RTC（`/dev/rtc1`）。
- **回退安全**：EFI 分区保留了 `dev12.15` 基线内核与设备树作为备用启动项，可在 U-Boot/systemd-boot 菜单中随时切换。

## 在电脑上校验与解包

在安装了 GNU `tar`、`zstd`、`coreutils` 与 `bash` 的 Linux 或 WSL 环境中执行（解包目录需预留至少 9 GiB 空间）：

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev13.0.tar
cd y700-tb320fc-prc-debian-dev13.0
bash unpack.sh ../dev13.0-images
(cd ../dev13.0-images && sha256sum --strict -c SHA256SUMS)
```

如需为自己的平板注入该机出厂蓝牙地址（由当前用户独占、权限 `0600` 或 `0400` 的单行地址文件），请在解包命令中加入：

```bash
bash unpack.sh --bluetooth-address /path/to/private-bt-addr ../dev13.0-images
```

## 每机专有固件与出厂校准

本通用发布镜像不含任何设备私钥、个人网络配置、蓝牙地址或受版权限制的出厂校准记录，首次开机时通过触屏创建本机密码。每台设备的蓝牙地址、CS35L45 扬声器校准与 SLPI 传感器校准请使用仓库中提供的 `scripts/prepare-bluetooth-identity.py`、`scripts/speaker-calibration.py` 与 `scripts/import-ssc-calibration.py` 从该机自身 Android 备份提取。详细实机验证记录见 [HARDWARE-VERIFICATION.md](HARDWARE-VERIFICATION.md)。
