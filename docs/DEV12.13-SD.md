# dev12.13 microSD 构建与验证

从已解包的国行 dev12.13 发布目录生成整卡镜像和两个外层 EFI 补充项。构建目录位于 Linux 文件系统，输出均为普通文件。主机需要 Bash、e2fsprogs、dosfstools、mtools、util-linux、cpio、GNU tar 和 zstd。首次用卡与返回内置系统的步骤见[随包说明](../packaging/sd-trial/dev12.13.zh_CN.md)。

```bash
bash scripts/build-test-card.sh "$IMAGES" "$WORK/card"
bash scripts/build-trial-entry.sh "$WORK/card" "$WORK/entry"
bash scripts/export-board-image.sh --card-only "$IMAGES" "$WORK/export" "$WORK/card" "$WORK/entry"
(cd "$WORK/export" && sha256sum --strict -c TRANSPORT-SHA256SUMS)
```

制卡器核对原始 6 GiB 根和 1 GiB EFI 的配对哈希。卡根的 `fstab` 用 GPT 根标签 `y700-test-root` 与 FAT UUID `12DC-1213`。试验 initrd 在只读挂载时检查本版 `tablet-desktop.lock.json`、发行号、挂载配置及同一设备上的 EFI 分区。两种菜单都启用此检查。内置盘菜单和卡上文件系统可共存，即使通用根 UUID 恰好相同。

| 经验证的文件 | SHA-256 |
| --- | --- |
| 解包后的源 `root.ext4` | `6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c` |
| 解包后的源 `linux-boot.fat` | `cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d` |
| `y700-test-card.img.zst` | `d645130b52014d304b92df856c26c9bffad078f343383ffd15cf62971837cbb8` |
| 解压后的 `y700-test-card.img` | `ddf304fa80ab704d0b3561072c0c819f47421db7653997fc4876396014133cd6` |
| 本次导出的 `trial-entry.tar.gz` | `6b0524bbfba562a33fd209592a0f04574c2043b4276cec5d450c8ccefe819353` |

## AArch64 启动验收

沿用板级固件测试目录 `$BOARD` 和解包的 QEMU 目录 `$QEMU`。正例的内置 EFI 位于 4096 字节扇区的虚拟盘，SD 位于 512 字节扇区的虚拟盘。测试程序使用虚拟机设备树和串口观察器，保留发布内核和 SD initrd。分别运行的两个内核都会正常关机；可在两次测试之间移走上一轮的临时大磁盘，避免额外占用空间。

```bash
bash tests/board-image-vm.sh "$IMAGES" "$BOARD" "$QEMU" "$WORK/primary" "$WORK/card" "$WORK/entry"
bash tests/board-image-vm.sh "$IMAGES" "$BOARD" "$QEMU" "$WORK/compat" "$WORK/card" "$WORK/entry" --fallback-120
bash tests/sd-trial-return/run.sh "$BOARD" "$QEMU" "$WORK/entry" "$WORK/returns"
```

两个正例分别选择 `y700-sd-12-13.conf` 与 `y700-sd-12-13-120.conf`。两个运行中的内核标识均与各自发布镜像一致，systemd 从卡的第二分区启动，将同卡第一分区挂载到 `/boot`，实查 1,241 项库存摘要均为 `5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098`。

缺卡、版本标成 dev12.12 的测试卡、同卡 EFI 序列号错误分别触发了指定的 initrd 拒绝原因。每个负例都经历两次固件启动，第二次在无人按键时进入原版 `debian.conf`，原内核的 PID 1 核对内置测试根后正常关机。另将有效的 dev12.12 根与 dev12.13 EFI 拼成可通过输入文件摘要检查的一组文件，制卡器拒绝该组合。重新生成的 dev12.12 SD initrd 与先前发布补充件逐字节相同。

这些结果覆盖早期身份检查发起的自动返回。启动后期卡死仍取决于硬件复位能力。实体机卡槽、电源循环和两种内核的内屏表现需分别在实物上验收。
