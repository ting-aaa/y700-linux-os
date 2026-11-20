# 通过 USB 试用 dev12.5，保留现有系统和 microSD

这条路径适用于已能从内置存储启动 Debian 的国行 TB320FC_PRC。电脑发送两个压缩镜像，平板可以边接收、边在 RAM 中解压。要保留账户和设置时，将解压流写成内置存储中的两个普通文件。两个文件共占 7 GiB，分区表、Android 槽位和当前 microSD 都沿用原来的布局。

实机已使用 USB 网络上的 SSH 接收 1,294,156,499 字节压缩数据。普通桌面账户解压并计算 SHA-256，用时 54 秒，两份结果与交付镜像一致。此次校验直接从管道读取，未保存镜像，前后启动编号和挂载来源一致。完整系统从 RAM 单独启动，以及从内置文件启动的**实机**结果，均需要各自的启动测试。[实机传输程序](../tests/file-trial-usb-stream.sh) · [完整镜像和解包说明](DEV12.5-IMAGE.md)

## 仅验证传输

在 Linux 电脑上解开完整 tar 包，保留其中的 `base/` 目录原样。下面的 `USB_SSH` 是项目使用的 USB SSH 包装脚本，固定平板主机密钥并支持标准输入。验证程序会检查实际路由是 `usb0`，然后在平板上以 `y700` 账户计算解压后的摘要。

```bash
bash tests/file-trial-usb-stream.sh "$USB_SSH" "$base"
```

## 准备持久试用

完整镜像的两个数据文件和启动菜单补充包配套使用。补充包 `file-trial-entry.tar.gz` 的 SHA-256 为 `240bafe25bce9c5c1629e78e3c758fdf67d24285c363710b6f8ff5a7d450134c`。先在电脑上验证补充包目录中的 `SHA256SUMS`，在新的私有目录 `entry` 解包，再检查里面的四项清单。固件加载这四个文件，从内置的 `/var/lib/y700-trial/dev12.5/root.ext4` 和 `linux-boot.fat` 分别挂载试用系统的根目录和 `/boot`。[补充包构建说明](../src/boot/file-trial.md)

准备写入时先运行只读检查，并将输出保存在电脑上。下例的 `entry` 是刚解开的目录，包含 `EFI` 和 `loader`。

```bash
bytes=$(wc -c < "$entry/loader/entries/y700-file.conf")
for f in "$entry"/EFI/y700-file/{kernel.efi,board.dtb,initrd}; do bytes=$((bytes + $(wc -c < "$f"))); done
bash "$USB_SSH" "bash -s -- --file-trial $bytes" < tests/sd-trial-preflight.sh
```

实际暂存会在内置 Debian 的系统分区新增 6 GiB 根文件和 1 GiB EFI 文件。以下步骤应在机主同意写入后执行。使用 Bash，令 `supplement` 指向已校验的 `file-trial-entry.tar.gz`。把脚本和补充包放在平板临时 RAM 目录，两个大镜像通过管道直接写入目标文件。

```bash
set -euo pipefail
scratch=$(bash "$USB_SSH" 'mktemp -d /run/y700-file-dev12.5.XXXXXXXX')
[[ $scratch =~ ^/run/y700-file-dev12\.5\.[a-zA-Z0-9]{8}$ ]]
tar -C scripts -cf - stage-file-trial-images.sh manage-file-trial-entry.sh |
    bash "$USB_SSH" "tar -C $scratch -xf -"
bash "$USB_SSH" "mkdir $scratch/entry && tar -C $scratch/entry -xzf -" < "$supplement"
cat "$base/root.ext4.zst" "$base/linux-boot.fat.zst" |
    bash "$USB_SSH" "bash -o pipefail -c 'zstd -qdc | bash $scratch/stage-file-trial-images.sh /'"
bash "$USB_SSH" "bash $scratch/manage-file-trial-entry.sh add $scratch/entry /boot"
```

数据接收程序先在私有目录预分配空间，再校验完整输入的长度、摘要和根文件系统身份，最后一起发布两个文件。目标已有这一版时会保留原先的设置并结束。菜单工具最后才放置 `y700-file.conf`，然后读回四个新增文件，并核对原来六个启动文件的摘要。以上操作完成后，平板仍处于当前会话。[接收程序](../scripts/stage-file-trial-images.sh) · [菜单工具](../scripts/manage-file-trial-entry.sh)

## 试启动和返回

现场重新启动后，在内置菜单里为本次开机选择 **Y700 dev12.5 (persistent files)**。首次通过屏幕键盘设密，随后在普通图形登录界面输入用户名 `y700` 和同一密码。再次手动选择试用项可继续上次的设置。让启动菜单按原来的五秒超时，会回到原 Debian。

试用系统以可写方式使用两个文件，正常关机会依次卸载内层系统、解除 loop 设备关联并卸载外层内置文件系统。试用系统的管理员仍有权限访问内置数据。文件目录缺失、根镜像被换成链接或系统身份不匹配时，已在虚拟机里验证试用项会发起重启并回到原 Debian 启动项。若整机卡死仍可能需要现场复位。[启动和关机实现](../src/boot/file-trial-init) · [双层文件系统检查](../tests/file-trial-positive/check-offline.sh)

从原 Debian 撤下试用项时，把同一份已校验的补充包和菜单工具放回临时目录，运行 `bash manage-file-trial-entry.sh remove /path/to/entry /boot`。工具在删除前核对四份文件的内容。两个大文件保留账户与数据，机主确认不再需要后可另行移除。
