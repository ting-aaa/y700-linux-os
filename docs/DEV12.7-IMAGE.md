# 拯救者 Y700 二代 Debian 开发镜像 dev12.7

这个归档面向国行 TB320FC_PRC，包含板级 U-Boot、EFI 分区和 6 GiB Debian 13 ARM64 根文件系统。dev12.7 在 dev12.6 的 1,115 个软件包基础上加入 UPower、Xfce 电源管理器及平板电池图标配置，共 1,124 个软件包。第一次登录仍使用触屏设密流程。平台组件版本为 `0.1.0~dev12.6`。

在 Xfce 顶栏的通知区域点按电池图标即可打开电源菜单。设备供电状态来自 Qualcomm 电池驱动和 UPower。测试平板接入 USB 充满电时，普通用户读到 100%、电池电流为零，桌面电池放电功率为 0 W。拔线后的续航和充电时间还需要实体放电与充电测试。

## 在 Linux 电脑上解包

把 TAR 和附带的 `SHA256SUMS` 放入同一目录。普通用户可执行以下命令，需要 GNU tar、Bash、coreutils、zstd 和至少 9 GiB 可用空间。解包目标是电脑上的新目录。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.7.tar
cd y700-tb320fc-prc-debian-dev12.7
bash unpack.sh ../dev12.7-images
(cd ../dev12.7-images && sha256sum --strict -c SHA256SUMS)
```

板级 U-Boot 摘要为 `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8`，EFI 分区摘要为 `495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6`。根镜像摘要随归档保存在 `base/RAW-SHA256SUMS`，完整软件包清单摘要为 `bbb696086ce1bb4a425dbf63876f12548e7e6a6048ed89415e64cb6a793eba6a`。通用镜像保留锁定的初始账户，蓝牙地址和传感器校准应按设备准备。[电源数据验证](UPOWER.md) · [设备专属配置](DEV12.6-IMAGE.md)
