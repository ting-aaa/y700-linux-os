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

三颗镜头的取景和拍照可从 **Y700 Camera** 打开。后置主摄在驱动确认识别出执行器和本机有效校准后，会显示 **对焦**。点击按钮启动一次对焦，扫描期间可以取消。使用模拟场景的平板内存测试已通过；真实合焦、待机唤醒和长时间图形负载需要实机测量。
