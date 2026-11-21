# dev12.5 文件镜像试启动

在 Linux 构建机上以普通账户运行。第一个目录来自完整 dev12.5 包的通用解包，第二个目录为尚未使用的输出路径。

```bash
bash scripts/build-file-trial-entry.sh "$images" "$work/entry"
(cd "$work/entry" && sha256sum --strict -c SHA256SUMS)
```

需要打包携带这四个文件时，可以从已校验的目录生成可复现的压缩包。归档内含部署文件和各自的 SHA-256 清单。

```bash
set -o pipefail
tar -C "$work/entry" --format=ustar --mtime=@1795150416 --owner=0 --group=0 \
    --numeric-owner --mode=0644 -cf - EFI/y700-file/{kernel.efi,board.dtb,initrd} \
    loader/entries/y700-file.conf SHA256SUMS | gzip -n > "$work/file-trial-entry.tar.gz"
```

构建器校对完整的 6 GiB 根镜像和 1 GiB EFI 镜像，从 EFI 镜像提取内核、PRC 设备树和 initrd。它在原始 gzip initrd 尾部追加第二个 cpio，包含启动与关机脚本。输出的四个 EFI 文件使用独立路径。启动菜单通过 `rdinit=/y700-file-trial-init` 选择本入口。

| 文件或挂载点 | 用途 |
| --- | --- |
| `EFI/y700-file/{kernel.efi,board.dtb,initrd}` | 本次启动专用内核、设备树和 initrd |
| `loader/entries/y700-file.conf` | 手动选择的一次试启动入口 |
| 内置系统的 `/var/lib/y700-trial/dev12.5/{root.ext4,linux-boot.fat}` | 持久根系统和 EFI 文件系统 |
| 试用系统的 `/` 和 `/boot` | 各自挂载一个 loop 块设备 |
| 试用系统的 `/run/initramfs/backing` | 仅 root 可进入的内置系统挂载点 |

入口先核对设备树、UFS 控制器、GPT 分区名、文件系统 UUID 和内置 Debian 身份。真实 UFS 在挂载前应用 75 MHz 上限。外层文件系统以 `ro,noload` 打开，检查私有目录和常规文件的权限、所有者、链接数、大小及两个内层 UUID，再只读核对内层 Debian 的身份文件。外层与内层 ext4 需要干净关闭。全部检查后切换到读写挂载，首次设密和后续设置保存在根镜像中。试用系统中的 root 仍有访问内置数据的权限。

正常关机时，systemd 把 PID 1 切换到 `/run/initramfs/shutdown`，旧系统位于 `/oldroot`。脚本卸载旧系统，释放并核对两个 loop，最后卸载外层文件系统。串口出现 `y700-file-trial: clean shutdown` 表示该次卸载完成。外部可对已关闭的两层 ext4 分别运行 `e2fsck -fn`，并从根镜像复查持久化数据。[systemd initrd 接口](https://systemd.io/INITRD_INTERFACE/)

镜像缺失或身份校验失败时，脚本请求立即重启。回到原系统依赖已核实的内置默认菜单和这次手动选择。只有显式选择试启动项才会再次进入该入口。硬件卡死仍可能需要现场重启。

## dev12.10 文件安装入口

dev12.10 使用 `/var/lib/y700-trial/dev12.10/{root.ext4,linux-boot.fat}`。启动器支持原始 6 GiB 根，以及已在离线状态下扩展到 32 GiB 的 ext4 根。两种容量分别要求 1,572,864 或 8,388,608 个 4 KiB 文件系统块，EFI 文件固定为 1 GiB。构建输入是开发包解出的通用 6 GiB 根和原始 EFI 文件。

```bash
bash scripts/build-file-trial-entry.sh --dev12.10 "$images" "$work/dev12.10-entry"
(cd "$work/dev12.10-entry" && sha256sum --strict -c SHA256SUMS)
bash scripts/manage-file-trial-entry.sh --dev12.10 add "$work/dev12.10-entry" "$internal_esp"
```

新条目为 `loader/entries/y700-file-12-10.conf`，启动文件在 `EFI/y700-file-12-10/`。添加工具核对内置 ESP 的卷号 `B6D4-FA81` 和返回入口，再写入四个文件。需要撤销这四个文件时，将同一命令的 `add` 换成 `remove`。添加和移除都保留原有默认启动项。

init 在只读阶段检查 `y700.release=dev12.10`、内外 ext4 的干净状态、内外系统身份、EFI 卷号，以及版本收据 `/var/lib/y700/build/video-player-update.lock.json` 的路径、所有者、权限和 SHA-256。dev12.9 与 dev12.10 共用 ext4 UUID。版本收据使错放的 dev12.9 在首次读写挂载前被拒绝。用户配置和扩容可以改变完整镜像摘要。dev12.10 的关机脚本检查文件系统类型，在卸载 `/run` 子目录时也会识别真实存储。

Linux 构建机可以分别测试菜单和启动路径。菜单回归在私有 FAT 上执行新增、重复新增、拒绝删除陌生文件及移除检查。ARM64 虚拟机直接载入条目对应的内核和 initrd，先试错版，再用 32 GiB 根进入 systemd，检查两个 loop、正常关机、持久化文件和离线文件系统状态。虚拟机使用 QEMU 设备树。

```bash
bash tests/file-trial-menu.sh --dev12.10 "$baseline_esp_files" "$work/dev12.10-entry"
bash tests/file-trial-edition.sh "$images" "$dev129_root" "$work/dev12.10-entry" "$work/boot-results"
```
