# Y700 二代 Debian dev12.13 开发镜像

本镜像面向国行联想拯救者 Y700 二代 TB320FC_PRC。系统使用 Debian 13 ARM64 和 Xfce 触屏桌面。首次启动用屏幕键盘设置本机密码，之后用自己的账户登录。内屏支持 60 Hz、120 Hz 与 200% 缩放。

## 日常操作

- 轻点顶栏「快捷设置」图标，或从图标向下拖动，可以调节亮度、音量、静音、蓝牙和自动旋转。应用菜单的「设置」中也有入口。
- 从「图形 → Y700 相机」选择后置主摄、前摄或后置微距。预览和保存的 JPEG 都会随内屏方向调整。相机启动时预选后置主摄。
- 蓝牙设备管理器提供触屏配对按钮。首次配对时按配件要求进入配对模式，按提示确认。屏幕键盘里的中文拼音候选词可以轻点一次提交。
- 在「设置 → 显示」选择内屏刷新率。默认项使用双刷新率内核，备用项使用 dev12.11 的 120 Hz 内核，两个入口共用本次安装的桌面和账户。

## 在电脑上解包

安装 GNU tar、zstd、coreutils 和 Bash 的 Linux 或 WSL 可运行下列命令。将发布的 TAR、`packages.tsv` 和 `SHA256SUMS` 放入同一目录，并为解包结果预留至少 9 GiB。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.13.tar
cd y700-tb320fc-prc-debian-dev12.13
bash unpack.sh ../dev12.13-images
(cd ../dev12.13-images && sha256sum --strict -c SHA256SUMS)
```

解包会在电脑上生成板级 U-Boot、1 GiB 的 EFI 文件系统、6 GiB 的 ext4 根文件系统以及校验清单。此通用包使用首次设密状态。每台平板的蓝牙地址、扬声器和传感器校准应来自该机自己的 Android 出厂数据。已装 U-Boot 的设备可以使用已有启动链。原厂 Android 设备需要先准备分区、备份和恢复路径，再部署这套原生 Linux 系统。
