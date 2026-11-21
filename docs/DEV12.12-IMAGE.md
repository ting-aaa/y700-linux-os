# Y700 二代 Debian dev12.12 开发镜像

适用于国行联想拯救者 Y700 二代（TB320FC_PRC）。dev12.12 将双刷新率内核、可用手指拖动的亮度滑杆和 Chromium 图形设置一起装入 Debian 13 ARM64 系统。平板上的 Xfce 默认采用 200% 缩放。首次进入桌面时用屏幕键盘设置自己的密码。

## 显示与触控

- **刷新率**　默认启动项为 `Y700 dev12.12 (60 / 120 Hz display)`，内屏首选 120 Hz。在「设置 → 显示」选择内屏、更改刷新率，再点「应用」并保留配置。另一个菜单项 `Y700 dev12.12 (dev12.11 kernel, 120 Hz only)` 可用原 120 Hz 内核启动同一个桌面和账户。
- **亮度**　在「设置 → 硬件 → 平板屏幕亮度」拖动 5–100% 滑杆，松手时应用。点「恢复打开时的亮度」可恢复进入设置前的精确亮度。
- **浏览器**　在「设置 → 硬件 → Chromium 图形」可为当前账户启用 GPU 加速。默认使用软件渲染。切换后完全退出并重新打开 Chromium。

两个 Linux 启动项共享设备树、initrd 和根文件系统。设备树包含后置主摄的 GT9768 对焦执行器和 PMK8350 闹钟。主摄、前摄、微距使用「Y700 相机」。每台平板的传感器和扬声器校准、蓝牙身份需取自本机。镜像使用独立的板级 U-Boot；已经配置 U-Boot 的开发机可以继续使用现有启动链。原厂 Android 启动链的设备需先完成相应的设备准备。

## 解包到电脑

在安装 GNU tar、zstd、coreutils 和 Bash 的 Linux 或 WSL 中，把发行 TAR、`packages.tsv` 和 `SHA256SUMS` 放在同一目录。为解包后的文件预留至少 9 GiB 可用空间。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.12.tar
cd y700-tb320fc-prc-debian-dev12.12
bash unpack.sh ../dev12.12-images
(cd ../dev12.12-images && sha256sum --strict -c SHA256SUMS)
```

输出为板级 U-Boot、1 GiB EFI 文件系统、6 GiB ext4 根文件系统和校验清单。这里的命令只在电脑上生成普通文件。启动菜单中的旧内核用于恢复显示兼容性；它与双刷新率内核共用同一套用户数据。移动卡的两个启动项应使用卡专属的根分区和 EFI 分区。安装或试启动时应保留平板现有的启动和数据恢复路径。
