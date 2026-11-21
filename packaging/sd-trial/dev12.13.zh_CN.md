# 国行 Y700 二代 dev12.13 microSD 试用包

适用 TB320FC_PRC，需已有本项目的板级 U-Boot 和可用的内置 Debian EFI 菜单。U-Boot 从内置 EFI 读取内核和 initrd，Linux 随后从 microSD 挂载根与 `/boot`。两项菜单共用卡上的桌面、账户和文件。

## 核对下载

在 Linux 或 WSL 中进入包含本说明和压缩镜像的目录。解压需预留 8 GiB。

```bash
sha256sum --strict -c TRANSPORT-SHA256SUMS
zstd -d --sparse y700-test-card.img.zst -o y700-test-card.img
sha256sum --strict -c SHA256SUMS
mkdir trial-entry
tar -xzf trial-entry.tar.gz -C trial-entry
(cd trial-entry && sha256sum --strict -c SHA256SUMS)
```

## 从卡启动及返回

1. 使用可以整卡覆盖的备用 microSD，容量至少 7,519,338,496 字节。确认读卡器中的目标卡后，用整盘镜像写入工具写入 `y700-test-card.img`。读回前 7,519,338,496 字节，其 SHA-256 应与 `SHA256SUMS` 一致。
2. 在可正常启动的内置 Debian 上确认实际内置 EFI 分区、当前默认项和剩余空间。文件镜像安装中的 `/boot` 是内层 FAT；应通过 EFI 的 `LoaderDevicePartUUID` 对照 `lsblk -o NAME,PARTUUID,PARTLABEL,FSTYPE,MOUNTPOINTS` 找到固件读取的外层 UFS EFI 分区。先核对该分区的 `loader/loader.conf` 有有限菜单倒计时和可用的内置默认项。将 `trial-entry/EFI/y700-sd-12-13/` 复制到该分区的同名新目录，再将补充件中的两个 `.conf` 放入 `loader/entries/`。如已有同名文件，先核对归属与内容。在外层 EFI 目录用补充件的 `SHA256SUMS` 校验六个文件。保留原来的内置启动项及其默认设置。
3. 用 `bootctl --esp-path=外层EFI挂载点 status` 和同一路径的 `bootctl list` 核对有效默认项：必须固定指向已能启动的内置 Debian 项，且没有待执行的一次性覆盖。使用 `@saved` 记住上一次选择的菜单需先恢复固定内置默认项，再进行试用。插卡，在内置 EFI 菜单手选 **Y700 dev12.13 microSD (60 / 120 Hz display)**。另一个带 **120 Hz only** 的 microSD 项使用 dev12.11 兼容内核。缺卡、旧版卡或同卡 EFI 身份错误会触发重启，随后由原 EFI 默认项启动。
4. 在卡上首次设密。将导出包中的 `identity.txt` 和 `verify-physical-boot.sh` 放在同一目录，运行 `sudo sh verify-physical-boot.sh` 核对实际 SD 控制器、分区、引导项、内核及 1,241 个已装软件包。正常关机后可取卡，再次开机返回原来的内置系统。

通用镜像的蓝牙地址、扬声器及传感器校准需使用本机数据。虚拟机验收涵盖两个内核及失败后的自动返回；实体板卡槽启动和实际介质读回应在使用这台设备时核验。
