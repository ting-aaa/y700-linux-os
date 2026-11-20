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
