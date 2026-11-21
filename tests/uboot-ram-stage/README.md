# 从国行 Y700 的 U-Boot USB 串口启动 RAM 接收器

这个入口使用已安装的 PRC U-Boot 2026.10 和 dev12.12 的存储控制器禁用版设备树。第一阶段经 USB 传内核、initrd 和 DT；第二阶段的 Linux 接收器通过自己的 USB 协议接收 `carrier.squashfs`。两阶段共用发布清单。[接收器构建脚本](../../scripts/build-ram-receiver.sh)

## 从主机检查

在 Windows PowerShell 的产品目录运行。将 `$Pin` 设为本次合格发布独立提供的 **SHA256SUMS 文件摘要**。单独计算手头目录的摘要只能检查传输完整性。

```powershell
$Tool = 'scripts/uboot-ram-stage.py'
$Bundle = 'out/dev12.12-ram-receiver'
uv run --offline --python 3.13 $Tool check $Bundle $Pin
```

`check` 只读主机文件。它验证所有五项（包括单独传输的大载荷），固定板级内核和 DT 的 SHA，并检查 ARM64 Image 的内存占用。其余动作要求在该台设备进行一次 RAM 试启动的授权。拔插或重启后重新检查。

## 在已有 U-Boot 中接管

11 月 18 日此板实测的入口是在重启时按住**音量下**进入 U-Boot 菜单。板级配置为 `bootdelay=0`，音量下触发 `bootmenu -1`，进入菜单后可等主机就绪。菜单实录提供 **Enable USB serial console** 和 **Drop to shell**；部分构建已在 preboot 开启 ACM。接入 USB，确保为该次试启动保留的 U-Boot 菜单或 `=>` shell。PC 工具等待唯一匹配的 ACM，发 Escape/Ctrl-C 请求 shell，收到行首 `=>` 后才发送带回车的命令。实机从运行中的 Debian 自动停在此提示符仍待验证。此板的 U-Boot preboot 自己会尝试 `scsi scan`；Linux 所用 DT 才是禁用 UFS/SD 的边界。[板级环境](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/u-boot/sm8475/asphalt/asphalt.env)（实机原始记录见下方）

```powershell
uv run --offline --python 3.13 $Tool inspect $Bundle $Pin
uv run --offline --python 3.13 $Tool stage $Bundle $Pin
uv run --offline --python 3.13 $Tool boot-staged $Bundle $Pin
```

`inspect` 查询 U-Boot 版本、bdinfo、命名地址和控制 DT，仅在 RAM 选择工作 DT。它检查型号、SoC 和 PRC 地区、完整 LMB 计数/边界/标志，以及该版固件实际合并的整段启动缓冲区预约。内核和 initrd 各有 128 MiB，DT 有 2 MiB。数值来自 Qualcomm 分配逻辑，运行地址由本次启动读取。[Qualcomm U-Boot 缓冲区分配](https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-snapdragon/board.c#L489-L527)

`stage` 默认用 ACM/YMODEM，逐包验 CRC16 并有限重传，结束核对接收字节数、三件在目标 RAM 的 CRC32、目标 DT 上的型号及两个存储控制器的 disabled 状态。历史 DT 传输和 CRC 成功；此前一次内核传输约 13.7 KiB/s 后由主机取消，按同速传 53.3 MB 约 63 分钟。`boot-staged` 重新检查身份、布局、当前 RAM 内容、DT 和内核参数，再发一条 `booti`。`boot` 可将上传与启动合在一次调用。启动请求回执之后另等 Linux 接收器握手。

有可用的 Windows fastboot 驱动时，可在 `stage` 或 `boot` 末尾加 `--fastboot <fastboot.exe>`。工具切到短时的 U-Boot USB fastboot，以一次性 RAM 环境值、版本及 128 MiB 容量确认同一设备，下载三件合包，在 RAM 内复制两件，再经 `continue` 返回串口并核对 CRC。旧实机已验证这种 stage、RAM 复制及串口 CRC；此次主机侧另外模拟了 USB 两次切换、错误设备和不完整下载。若 WinUSB 未绑定，沿用默认 ACM。进入 fastboot 后缺主机驱动时，历史菜单记录的恢复方式是短按音量键退出，随后重新出现 ACM。操作工具只请求临时 RAM 和环境变量。[U-Boot USB fastboot 接口](https://docs.u-boot.org/en/latest/android/fastboot.html) · [continue 回到调用者](https://github.com/u-boot/u-boot/blob/master/drivers/usb/gadget/f_fastboot.c)

11 月 21 日 Windows 主机驱动库无 Google `android_winusb.inf`，历史相同 USB 型号的复合接口保留 `usbser` 绑定。本机同时有 Windows 自带的 WinUSB 驱动文件；能否用于下载取决于 fastboot 接口的实际绑定。11 月 17 日临时绑定 Google r13 需要管理员确认，用后已卸载；本地驱动目录的签名校验仍为 Valid。脚本不管理主机驱动。

## 通过日常启动分区加快串口上传

11 月 21 日已在此台设备的外层 `linux-boot` FAT 中核对 `/EFI/y700-display-12-11.efi`。文件为 39,410,176 字节，SHA-256 为 `0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60`，与发布内核逐字节匹配。保留此次核对所得的 GPT **PARTUUID** 作为下面的 `$PartUuid`。其他设备需要核实其自己的分区和该文件。[内核对应的显示选项](../../docs/PANEL-REFRESH-OPTION.md)

```powershell
uv run --offline --python 3.13 $Tool stage $Bundle $Pin --esp-kernel $PartUuid
uv run --offline --python 3.13 $Tool boot-staged $Bundle $Pin
```

启用此选项允许 U-Boot 只读查询其已扫描的 SCSI LUN 0–7。找到唯一匹配标签和分区 UUID 的分区后，工具仅从上述固定路径向已验证的 RAM 地址读取文件，同时限制最大读取长度。文件大小、加载地址、实读长度和完整 RAM 的 CRC32 均通过，才跳过该内核的 YMODEM 上传，回执为 `esp_kernel_hit=1 usb_bytes_saved=39410176`。按前述实测速率可节省约 47 分钟。任一文件或身份检查未匹配且 shell 仍响应时，工具经 USB 上传全部三件。丢失 shell 提示符即中止。后续 `boot-staged` 仍验证三件与禁存储 DT。[U-Boot fatload 长度与返回值](https://docs.u-boot.org/en/latest/usage/cmd/fatload.html)

## 复核

在 PC 指向早期实验区的 `asphalt-debian` 目录、候选目录和独立清单摘要，运行：

```powershell
uv run --offline --no-project --python 3.13 python -B tests/uboot-ram-stage/replay.py $HistoricalAsphaltDebian $Bundle $Pin
```

回放直接读取 `physical-20261117-ram-recovery/{uboot-console,linux-handoff-console}.log` 和当时三件镜像，重新计算原机三项 CRC；另外读取 `physical-20261116-uboot-prc` 的版本记录及 PRC 控制树。合成负例覆盖错板、预约项缺失、受保护范围、地址冲突、截短数据、错误目标 DT 状态及错误命令行。模拟 YMODEM 检查重发、尾包及取消；模拟 fastboot 检查同一临时标识、合包字节、复制定位和失败退出。测试结束报告 `hardware_commands=0`。历史原始日志留在本地。

Linux 主机还可运行独立的 AArch64 QEMU U-Boot FAT 检查。它使用临时合成 GPT、FAT32、随机分区 UUID 和实际 39,410,176 字节内核，通过相同的生产代码执行分区查询、加载与 RAM 校验。已实测正确身份命中、错身份拒绝和原 GPT 镜像 SHA 前后一致。此项测试的 U-Boot 为 QEMU virt 版（SHA-256 `ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f`）。物理机的 U-Boot 从日常分区加载这一特定文件仍待试启动验证。

```sh
uv run --offline --no-project --python /usr/bin/python3 python -B tests/uboot-ram-stage/esp-qemu.py "$Bundle/kernel.efi" "$QemuUBoot"
```
