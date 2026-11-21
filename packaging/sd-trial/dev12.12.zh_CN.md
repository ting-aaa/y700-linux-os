# 国行 Y700 二代 dev12.12 microSD 开发包

适用 TB320FC_PRC，已配置本项目的板级 U-Boot 和可正常启动的内置 Debian。测试机的 U-Boot 从内置 EFI 分区读内核，Linux 内核接手后才可从卡槽读取 Debian。因此试用需要整卡镜像及配套的内置 EFI 菜单文件。系统默认账户在首次进入时通过屏幕键盘设置密码。蓝牙地址及扬声器、传感器校准依赖本机数据。

## 在电脑上核对

在 Linux 或 WSL 将当前目录切换到发行包，运行以下命令。需要 Bash、GNU tar、coreutils 和 zstd。解包会在电脑生成普通文件，预留 8 GiB 可用空间。

```sh
sha256sum --strict -c TRANSPORT-SHA256SUMS
zstd -d --sparse y700-test-card.img.zst -o y700-test-card.img
sha256sum --strict -c SHA256SUMS
mkdir trial-entry
tar -xzf trial-entry.tar.gz -C trial-entry
(cd trial-entry && sha256sum --strict -c SHA256SUMS)
```

## 在准备好的开发机试用

1. 选用一张可以整卡覆盖的备用 microSD。核对读卡器和实际容量，至少 7,519,338,496 字节（标称 8 GB）。用整盘镜像写入工具将 `y700-test-card.img` 写入该卡，校验读回前 7,519,338,496 字节的 SHA-256 与 `SHA256SUMS` 一致。
2. 从正常工作的内置 Debian 核对实际 EFI 分区、当前默认启动项、可用空间和已有菜单。记录原来的可启动项。将 `trial-entry/EFI/y700-sd-12-12/` 的四个文件放进内置 EFI 的同名新目录，再将 `trial-entry/loader/entries/` 的两个文件放到内置 EFI 的 `loader/entries/`。如目标文件已存在，先核对归属和摘要。以 EFI 分区为当前目录，使用补充件内 `SHA256SUMS` 核对六个文件。
3. 插卡后在内置 EFI 菜单手选此次使用的 dev12.12 microSD 启动项。普通项支持 60/120 Hz，兼容项使用原 120 Hz 内核，两项共享卡上的账户与文件。保留内置 Debian 为日常默认项，便于下次开机返回。
4. 进入卡上的桌面后，将本包的 `identity.txt` 和 `verify-physical-boot.sh` 放在同一目录，运行 `sudo sh verify-physical-boot.sh`。它检查实际分区、SD 控制器、EFI 选择、运行的内核，以及 1,240 个软件包。随后正常关机或重启，选择原内置 Debian。

镜像构建、实测范围和校验值见产品源码 `docs/DEV12.12-VERIFICATION.md`。卡上没有本机数据的通用系统仍需完成设备专属配置。
