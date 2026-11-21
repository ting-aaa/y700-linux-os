# Y700 二代 Debian dev12.15 全新安装

国行 TB320FC_PRC 的 dev12.15 在 Xfce 应用菜单提供“软件更新”，并为默认双刷新率内核和备用 120 Hz 内核安装 USB 数字音频驱动。图形更新程序通过 Debian PackageKit 刷新已配置的软件源，由用户选择并确认安装。USB 耳机、声卡或有源转接器需兼容 USB Audio Class。首次登录时用触屏创建本机密码。

## 在电脑上还原镜像

准备同目录的 dev12.15 增量 TAR、随包的 `SHA256SUMS` 和 `packages.tsv`，以及原有的 dev12.13 完整 TAR。Linux 或 WSL 需要 Bash、GNU tar、coreutils、util-linux、zstd、xdelta3 和至少 18 GiB 可用空间。把下面命令中的基包路径换成自己的实际位置。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.15.tar
bash y700-tb320fc-prc-debian-dev12.15/unpack.sh \
    ../dev12.13-board/y700-tb320fc-prc-debian-dev12.13.tar dev12.15-images
(cd dev12.15-images && sha256sum --strict -c SHA256SUMS)
```

解包器核对基包、还原 6 GiB 的 dev12.15 根文件系统，随后逐一校验 U-Boot、EFI、根和身份清单。命令只在电脑上生成普通文件。安装与恢复沿用 TB320FC_PRC 已验证的分区流程。开发机的两个制品目录分别是 `out/dev12.13-board/` 和 `out/dev12.15-board/`。

如已取得该机的原厂蓝牙地址，可在 `unpack.sh` 后加入 `--bluetooth-address PRIVATE_FILE`。文件由当前用户独占，权限为 0600 或 0400。此操作额外需要 e2fsprogs，会回读个性化结果。扬声器和传感器使用该机自身的出厂校准。[dev12.14 个性化说明](DEV12.14-IMAGE.md) · [USB 数字音频](USB-AUDIO.md)
