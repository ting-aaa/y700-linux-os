# Y700 二代 Debian dev12.11 开发镜像

适用设备为国行联想 Y700 二代（TB320FC_PRC）。镜像包含 Debian 13 ARM64、200% 缩放的 Xfce 触屏桌面、Adreno 730 的 GMU 修复、WPA3 客户端更新、后置主摄对焦支持，以及可设置定时闹钟的 PMK8350 RTC。RTC 使用 `rtc1`，保留原有的系统时钟策略。

## 在电脑上解包

将发行 TAR、`packages.tsv` 和 `SHA256SUMS` 放在同一目录。在安装 GNU tar、zstd、coreutils 和 Bash 的 Linux 电脑上，至少预留 9 GiB 空间。以下命令只处理电脑上的文件。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.11.tar
cd y700-tb320fc-prc-debian-dev12.11
bash unpack.sh ../dev12.11-images
(cd ../dev12.11-images && sha256sum --strict -c SHA256SUMS)
```

输出包含板级 U-Boot、1 GiB EFI 文件系统和 6 GiB Debian 根文件系统，以及对应的校验清单。板级设备树同时描述主摄 GT9768 对焦马达和 RTC 闹钟。设备专属的蓝牙地址、传感器校准和用户密码在部署时配置。

三颗镜头的取景和拍照可从 **Y700 Camera** 打开。后置主摄在驱动识别出执行器和本机有效校准后显示 **对焦**，扫描期间可取消。实机已读到后置镜头的对焦控制范围，真实场景的光学合焦仍待验证。已安装的系统完成了两次浅睡、一次深睡的 RTC 唤醒，以及醒后的图形与 1080p 视频硬解测试。[实机验证](DEV12.11-VERIFICATION.md)

这份归档默认让 Chromium 使用软件渲染。另有配套桌面更新，在「设置管理器 → 硬件 → Chromium 图形」提供每个账户自己的加速开关。这台开发用平板已经装好该更新。[更新包、安装和回退](CHROMIUM-GRAPHICS.md)

开发平板还装有可拖动的 5–100% 亮度滑杆，以及启动时可手选的双刷新率内核。日常默认内核仍为 120 Hz。从本页的封存镜像新装时，可分别使用配套的软件包和 EFI 文件添加这两项功能。[亮度软件包](BRIGHTNESS.md) · [60/120 Hz 可选菜单](PANEL-REFRESH-OPTION.md)
