# 通过 USB 试用 dev12.5，保留现有系统和 microSD

已经在平板上使用 Debian 的用户可以照常使用。下面的步骤供开发测试时单独启动新版镜像，并检查新桌面和设置能否在关机后继续使用。准备这项测试时无需额外购买存储卡。

这条路径适用于已能从内置存储启动 Debian 的国行 TB320FC_PRC。电脑发送两个压缩镜像，平板可以边接收、边在 RAM 中解压。要保留账户和设置时，将解压流写成内置存储中的两个普通文件。两个文件共占 7 GiB，分区表、Android 槽位和当前 microSD 都沿用原来的布局。

实机已使用 USB 网络上的 SSH 接收 1,294,156,499 字节压缩数据。普通桌面账户解压并计算 SHA-256，用时 54 秒，两份结果与交付镜像一致。此次校验直接从管道读取，未保存镜像，前后启动编号和挂载来源一致。完整系统从 RAM 单独启动，以及从内置文件启动的**实机**结果，均需要各自的启动测试。[实机传输程序](../tests/file-trial-usb-stream.sh) · [完整镜像和解包说明](DEV12.5-IMAGE.md)

## 临时在内存里运行桌面

RAM 试用包内含原版 6 GiB 根文件系统的全部字节和 1,112 个 Debian 软件包。内核按需读取压缩内容，桌面把新密码、下载和应用设置写入单独的内存文件系统。关机后这些内容随会话消失。需要保留文件和设置时，可以继续使用已经安装的 Debian，或使用下文的持久试用方案。

在 Linux 电脑上，用解包后的通用镜像构建。需要 GNU coreutils、Bash、mtools、cpio 和支持 zstd 的 squashfs-tools。以下命令只在电脑上创建目录。生成物包含板级固件，保存在本地。

```sh
bash scripts/build-ram-trial.sh /path/to/dev12.5-images /path/to/dev12.5-ram
(cd /path/to/dev12.5-ram && sha256sum --strict -c SHA256SUMS)
```

启动包带有板级内核、设备树、命令行和 initramfs。RAM 入口将压缩文件系统和其中的 ext4 都以只读方式挂载，上层的临时写入使用 tmpfs。试用会话为自己的根目录提供独立的挂载配置，并向磁盘设备设置只读保护。若将来从现有 Debian 通过 ARM64 `kexec_file_load` 交接内核，后继内核会沿用当前启动的设备树。平板的真实显示、触控、USB 和返回原系统都需要在这条启动路径上单独验证。[构建脚本](../scripts/build-ram-trial.sh) · [RAM 启动入口](../src/boot/ram-trial-init) · [ARM64 内核交接实现](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/kernel/machine_kexec_file.c#L140-L177)

R2 的 initramfs 为 1,257,411,172 字节，SHA-256 为 `88635b98e707fa1ba87d2f8e20b1fa1d5d00427c6ebf99c6ddfd833fc1d6e580`。在分配 9 GiB 内存的 ARM64 虚拟机中，直接启动后，全系统核对了 1,112 个软件包，空闲可用内存读数为 7,649,700 KiB。模拟触屏完成首次设密、图形登录和普通用户 Xfce 会话，随后正常关机。该次启动全程没有虚拟磁盘或活动交换区。[无盘桌面验收程序](../tests/ram-trial/README.md)

从旧内核切换时，启动固件会影响结果。虚拟机直接加载旧内核时，后继系统在解压前期遇到中断控制器内存冲突。改由 EDK II 的 EFI 固件启动旧内核后，保持中断控制器及其中断转换服务开启，交接检查确认三个加载段都避开了四张活动中断表。新版接管后，模拟触屏完成设密和登录，普通用户进入 Xfce，正常关机后镜像校验仍一致。测试使用与平板现有 Debian 启动文件摘要一致的旧内核，以及 R2 的板级候选内核。虚拟机采用 Cortex-A72 和虚拟设备树，平板所用的 U-Boot 固件仍需独立验证。[EFI 交接测试](../tests/ram-handover/efi-first.sh) · [区间检查](../tests/ram-handover/check-irq-placement.awk)

另用同一内核和 Debian 257.13 的 udev 验证存储保护。两轮分别使用全新的虚拟磁盘，开机时挂一块，启动后通过 USB 加入另一块。设备识别完成后，两块盘及其分区都拒绝了实际的 4 KiB 写入，关机后的整盘摘要与开机前一致。平板的内置 UFS 和卡槽仍需实机验证。管理员可以主动解除 Linux 块设备的只读标志。[磁盘保护测试](../tests/ram-media/README.md)

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
    bash "$USB_SSH" "bash -o pipefail -c 'zstd -qdc | bash $scratch/stage-file-trial-images.sh --inherit-bluetooth /'"
bash "$USB_SSH" "bash $scratch/manage-file-trial-entry.sh add $scratch/entry /boot"
```

数据接收程序先在私有目录预分配空间，再校验完整输入的长度、摘要和根文件系统身份，最后一起发布两个文件。目标已有这一版时会保留原先的设置并结束。菜单工具最后才放置 `y700-file.conf`，然后读回四个新增文件，并核对原来六个启动文件的摘要。以上操作完成后，平板仍处于当前会话。[接收程序](../scripts/stage-file-trial-images.sh) · [菜单工具](../scripts/manage-file-trial-entry.sh)

上述命令适用于原 Debian 已配置本机蓝牙地址的平板。`--inherit-bluetooth` 在校验通用镜像后，从平板上的 `/etc/y700/bluetooth-address` 读取本机地址，直接写入试用根镜像并读回核对。个人地址全程留在平板上。电脑上的回环文件系统已用虚构地址验证这一流程。原系统缺少地址时，去掉该参数可暂存通用镜像，稍后按指南配置。[蓝牙地址配置](DEV12.5-IMAGE.md) · [暂存回归测试](../tests/file-trial-staging.sh)

原 Debian 保留自己的配对密钥。首次在试用系统使用蓝牙键鼠时需要配对。如果配件在重新配对时替换了旧密钥，回到原 Debian 后也可能需要再配一次。[BlueZ 配对记录格式](https://bluez.readthedocs.io/en/latest/settings-storage/)

通用镜像启动后会尝试从本机 `persist` 分区读取扬声器校准。首次启动传感器服务时也会尝试导入本机出厂校准。[扬声器校准](SPEAKERS.md) · [传感器校准](SSC-CALIBRATION.md)

## 试启动和返回

现场重新启动后，在内置菜单里为本次开机选择 **Y700 dev12.5 (persistent files)**。首次通过屏幕键盘设密，随后在普通图形登录界面输入用户名 `y700` 和同一密码。再次手动选择试用项可继续上次的设置。让启动菜单按原来的五秒超时，会回到原 Debian。

ARM64 虚拟机从同一组镜像完成了连续两次图形登录。首次用模拟触屏在屏幕键盘上设密，随后通过 LightDM 进入普通用户的 Xfce 桌面。正常关机、重新开机后，系统跳过设密，同一个密码再次进入桌面。两次关机均依次卸载了内外文件系统，事后只读检查确认两层 ext4 和内层 FAT 都干净，根镜像中保留了账户设置标记。[虚拟机验证程序](../tests/file-trial-positive/README.md)

同一版 ARM64 镜像还通过了一轮登录后的触屏测试。普通用户进入 Xfce 后，模拟手指点进 GTK 输入框，Onboard 自动弹出，逐键点按后输入框收到 `hello`。点开顶栏扬声器图标可以切换静音，也可以用滑块把虚拟输出从 100% 调到 29%、77%，再恢复到 100% 和原来的非静音状态。测试使用静音虚拟输出；平板扬声器的实机播放另有记录。[触屏验收程序](../tests/file-trial-positive/README.md) · [扬声器实机记录](SPEAKERS.md)

试用系统以可写方式使用两个文件，正常关机会依次卸载内层系统、解除 loop 设备关联并卸载外层内置文件系统。试用系统的管理员仍有权限访问内置数据。文件目录缺失、根镜像被换成链接或系统身份不匹配时，已在虚拟机里验证试用项会发起重启并回到原 Debian 启动项。若整机卡死仍可能需要现场复位。[启动和关机实现](../src/boot/file-trial-init) · [双层文件系统检查](../tests/file-trial-positive/check-offline.sh)

本版的关机测试覆盖试用系统和承载它的内置存储。若桌面已挂载 microSD 或 USB 硬盘，请在试用系统关机前从文件管理器弹出该卷。卡可以留在卡槽内。

从原 Debian 撤下试用项时，把同一份已校验的补充包和菜单工具放回临时目录，运行 `bash manage-file-trial-entry.sh remove /path/to/entry /boot`。工具在删除前核对四份文件的内容。两个大文件保留账户与数据，机主确认不再需要后可另行移除。
