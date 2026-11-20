# 拯救者 Y700 二代 Debian 平板镜像 dev12.5

适用机型为国行联想 TB320FC_PRC。这个本地开发包将 U-Boot、EFI 启动分区和 Debian 13 ARM64 根文件系统放在同一个 tar 归档里。根文件系统包含全部 1,112 个软件包。通用镜像保留首次设置密码流程，每台设备单独配置蓝牙地址、扬声器和传感器校准。

Xfce 桌面采用 200% 默认缩放，打字键盘接入时会收起屏幕键盘，断开后可随输入焦点恢复。相机应用支持三摄预览和 JPEG 快门，传感器运行时包含桌面代理，扬声器使用本机校准。主机软件包包括 `y700-platform 0.1.0~dev12.5`、`onboard 1.4.1-10+y7002`、`y700-camera-qcam 0.7.2-1~bpo13+1.y7003` 和 `y700-ssc-runtime 0.1.3`。系统沿用该板型的 GPU 候选内核。Wi-Fi 在早期启动和系统运行阶段均选择与内核公钥匹配的签名监管数据库。

## 在 Linux 电脑解包

准备 Bash、GNU coreutils、tar 和 zstd。在有至少 9 GiB 可用空间的 Linux 文件系统中，以普通用户运行。命令从 `y700-tb320fc-prc-debian-dev12.5.tar` 和随附的 `SHA256SUMS` 所在目录开始。最后的目标目录须为新路径。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.5.tar
cd y700-tb320fc-prc-debian-dev12.5
bash unpack.sh --verify
bash unpack.sh ../dev12.5-images
(cd ../dev12.5-images && sha256sum --strict -c SHA256SUMS)
```

| 解包后的文件 | 用途 | 原始大小 |
| --- | --- | ---: |
| `asphalt-prc-u-boot.img` | TB320FC_PRC 的 U-Boot | 41,406,464 字节 |
| `linux-boot.fat` | EFI 启动分区，含内核、设备树和 initramfs | 1,073,741,824 字节 |
| `root.ext4` | 完整 Debian 根文件系统 | 6,442,450,944 字节 |
| `identity.txt` | 镜像标识、根分区 UUID、软件包清单摘要和图形内核标识 | 文本 |

这些命令只在电脑上解包。实际启动还需要对应机型的引导和分区布局。整包的实机冷启动、休眠恢复和实体蓝牙键鼠仍待确认。

## 为一台平板准备蓝牙地址

如已有这台平板的原厂 Android 属性记录，可在解包时写入该机地址。还需要 uv、Python 3 和 e2fsprogs。以普通用户在权限受限的本地目录保存属性记录和生成的地址文件。下例从已展开的归档目录运行。

```bash
umask 077
uv run --offline --no-project --python /usr/bin/python3 python prepare-bluetooth-identity.py \
  --getprop /private/this-tablet-getprop.txt --output /private/this-tablet-address
bash unpack.sh --bluetooth-address /private/this-tablet-address ../dev12.5-personal
(cd ../dev12.5-personal && sha256sum --strict -c SHA256SUMS)
```

个性化后的 `root.ext4` 内含这台平板的地址。输出目录中的 `SHA256SUMS` 对应个性化结果，`UNPERSONALIZED-SHA256SUMS` 记录通用镜像校验值。
