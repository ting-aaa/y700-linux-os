# dev12.6 在 ARM64 EFI 固件下的内核交接

测试在电脑上的 QEMU `virt` 板运行。第一个内核是平板原 Debian 的 EFI 内核，SHA-256 为 `9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db`。后继内核和 initramfs 直接取自 dev12.6 RAM 包，摘要分别为 `4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1` 和 `ee4aceddc0302ff966c7d71f771e66302a50e83a3344e3f835e9a9cb40745946`。两组测试均使用 9 GiB 内存、三个 Cortex-A72 核、启用 ITS 的 GICv3 和虚拟板的设备树。

## 验证结果

两组都由原内核通过 `kexec_file_load` 交给 dev12.6，新内核的设备树报告 `linux,booted-from-kexec`。两次都加载了相同的 1,261,843,044 字节 initramfs。桌面启动后，来宾系统读到 1,115 个软件包，清单摘要为 `a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98`。根文件系统以只读 ext4 挂载在 SquashFS 上，临时写入落在 tmpfs。两次均观测到零外部磁盘、零活动交换设备。

在首次设置界面，模拟手指输入两次不一致的密码时账户保持锁定。两次一致后进入登录界面，测试继续通过屏幕键盘输入账户密码，LightDM 的 PAM 认证成功，普通用户进入同一会话的 Xfce。两台虚拟机都正常关机，返回码为 0，启动包四项输入的摘要与开机前一致。

| PC 上的固件 | 旧内核与后继内核报告的固件 | 加载前 / 交接前 | 本地收据及 SHA-256 |
| --- | --- | --- | --- |
| QEMU ARM64 U-Boot 2026.10 | 两次均为 Das U-Boot EFI 2.11 | 四张中断表均有保留区，三个加载段均避开这些表 | `out/dev12.6-ram-handover/uboot.log` · `af8cb635c5d8a801b7fd5da64d06e193b88e93eeed1af2c33b14e4c0a7fe3182` |
| Ubuntu EDK II 2025.11-3ubuntu7.3 | 两次均为 EDK II EFI 2.7 | 四张中断表均有保留区，三个加载段均避开这些表 | `out/dev12.6-ram-handover/edk2.log` · `5801f9075cb428af9afe00cc4849698244bf5c570162afea98d5fbe9760fe244` |

## 固件和内存检查

Linux 从 EFI 配置表获取跨内核使用的内存保留信息。装载后继镜像前，测试程序核对虚拟板身份、EFI、`MEMRESERVE`、ITS 和在线 CPU 数目，并确认 `/proc/iomem` 的保留区完整覆盖活动的 LPI 属性表及每个 CPU 的待处理中断表。缺少任一项便关机。内核通过正常的 `kexec_file_load` 接口装载镜像后，程序再次检查实际加载段与四张表均无交叠，再请求交接。[检查程序](../tests/ram-handover/first-kernel.c) · [区间检查与测试](../tests/ram-handover/check-placement.sh)

U-Boot 组使用 QEMU ARM64 版 U-Boot 和板级 EFI 分区里的 `BOOTAA64.EFI`。测试把原内核、虚拟设备树和小型首阶段 initramfs 放在只读的虚拟 USB EFI 分区，通过标准 EFI 启动项加载。旧内核报告 EFI 固件名称后，QEMU 拔除这份介质。旧内核在 RAM 中通过独立的 virtio 串口接收后继内核和完整 initramfs，逐项校验 SHA-256。EDK II 对照组从首阶段 initramfs 直接取得两份文件。后继系统通过自己的设备树、挂载和软件包数据库确认启动来源、RAM 根文件系统和 dev12.6 版本。[U-Boot 中的 UEFI](https://docs.u-boot.org/en/latest/develop/uefi/uefi.html) · [QEMU ARM 板配置](https://docs.u-boot.org/en/latest/board/emulation/qemu-arm.html)

旧内核的板级设备树和 dev12.6 包内设备树逐字节相同，SHA-256 为 `1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d`。树中有一个 GICv3 和一个 ITS 节点。既有的原系统实机日志记录了 U-Boot EFI 2.11、`MEMRESERVE`、一张属性表和八张 CPU 待处理中断表。实机 U-Boot 装在 Android boot v2 容器中，针对 SM8475 的引导接口和外围设备构建。本地摘要记录在 `out/dev12.6-ram-handover/board-record.log`，SHA-256 为 `6f68661260e87a4fbbdd943770249e78a41433d2b1503fe0475f6be0939dad00`。

## 当前平板的九张中断表

2026-11-21，在仍运行原内核的 TB320FC_PRC 上，通过已锁定主机密钥的 USB SSH 做了两次只读检查。两份缩减报告逐字节相同。运行内核的 ELF notes 匹配原版，CPU 0–7 在线，日志来自本次启动，显示 Das U-Boot EFI 2.11、EFI 内存保留配置表和一个 ITS。以下每项均检查完整的 65,536 字节，起始页或部分覆盖均不能通过。

| 本机数据源 | 一张 LPI 属性表 | 八张 CPU 待处理表 |
| --- | ---: | ---: |
| `/proc/iomem` 中位于 System RAM 下的 `reserved` 子资源 | 1/1 | 8/8 |
| 原内核 `memblock/reserved` 中的保留区 | 1/1 | 8/8 |
| 运行设备树 `reserved-memory` 各启用节点的固定 `reg` 区间 | 0/1 | 0/8 |

这种差别与原内核源码相符。ITS 在 EFI 系统上将新分配的 LPI 表交给 `efi_mem_reserve_persistent()`。EFI 将区间登记为 `reserved`，遇到 System RAM 父资源时将其插入为子项。这个内核启用了 `CONFIG_ARCH_KEEP_MEMBLOCK`，资源登记成功后还会调用 `memblock_reserve()`。普通文件式 kexec 会先尝试 CMA 连续分配。需要另找地址时遍历 `memblock.memory` 减去 `memblock.reserved` 的区间。因此一条 System RAM 记录本身不足以证明保护，活动 LPI 表落在静态 DT 保留区以外也不足以判定遗漏。如果某个区间只在 iomem 中标为保留、在 memblock 中却缺失，兜底分配器就可能把它作为目标段，单凭 iomem 无法排除冲突。本次九张表的两个视图均完整。EFI 的 `MEMRESERVE` 来自配置表。本次检查只核对了有限的 EFI 变量文件名，没有读取变量值或物理内存。[EFI 保留逻辑](https://github.com/torvalds/linux/blob/v7.3/drivers/firmware/efi/efi.c) · [ITS 分配](https://github.com/torvalds/linux/blob/v7.3/drivers/irqchip/irq-gic-v3-its.c) · [文件式 kexec 分配](https://github.com/torvalds/linux/blob/v7.3/kernel/kexec_file.c)

dev12.8 RAM 包的内核文件为 39,410,176 字节，ARM64 Image 标头声明内存跨度 39,976,960 字节、文本偏移为零。initrd 为 1,265,087,076 字节，按 4 KiB 向上取整后需要 1,265,090,560 字节。平板检查前后 `kexec_loaded` 都为 0。本次没有加载或卸载镜像、提出内核切换请求，三个实际目标段的位置仍未知。后继内核接管、中断控制器重用、显示、触控、USB 和冷启动恢复仍需独立实机验证。[dev12.8 RAM 包与校验值](DEV12.8-RAM-TRIAL.md)

本地记录为 `out/dev12.8-ram-handover-board/board-reservations.log`，SHA-256 为 `f1d83c0775475e7252617dd0a9ab7cf8b103ce478e197a7c8b3b113f1eeb77ab`。验证器可在缺少一字节、CPU 重复或缺失、仅有 System RAM 父区间、或 iomem 与 memblock 记录不符时拒绝通过。复测只向终端输出计数和覆盖状态。[采集入口](../tests/ram-handover/board-reservations.sh) · [反例](../tests/ram-handover/test_board_reservations.py)

```sh
bash tests/ram-handover/board-reservations.sh "$pinned_usb_ssh"
uv run --no-project --offline --python /usr/bin/python3 python -B tests/ram-handover/test_board_reservations.py
```

## 接管后使用的设备树

当前 ARM64 的 `kexec_file_load` 接口接收内核和 initrd 的文件描述符、命令行与标志。原内核的 `load_other_segments()` 让 `of_kexec_alloc_and_setup_fdt()` 从 `initial_boot_params` 复制**本次启动时的扁平设备树**，其中包含启动固件的修正，再更新 initrd 区间、启动参数和 `linux,booted-from-kexec` 等属性。辅助程序只打开内核与 initrd，交付目录中的外部 `board.dtb` 没有传入该接口。[本项目调用点](../tests/ram-handover/first-kernel.c) · [ARM64 加载器](https://github.com/torvalds/linux/blob/v7.3/arch/arm64/kernel/machine_kexec_file.c) · [设备树复制逻辑](https://github.com/torvalds/linux/blob/v7.3/drivers/of/kexec.c)

普通 dev12.8 沿用同一板级 DTB，具备研究这条 RAM 路径的输入条件。在当前平板设备树中，PMK8350 RTC 状态为 `disabled`，两颗 CCI 节点均没有 `assigned-clock-rates`。在 PC 上替换外部 DTB 然后执行现有文件式调用，不能验证启用 RTC 或给 CCI 指定 37.5 MHz 的候选。此类候选需要从实际提供该树的启动入口验证，并在进入 Linux 后核对相关属性。[RTC 探测树](SUSPEND-ROUTING.md) · [CCI 时钟证据](CAMERA-FOCUS-PROBE.md)

## 在 Linux 电脑上复测

准备可运行 QEMU AArch64 的主机、uv、Python 3、ARM64 静态 C 编译器、GNU cpio、mtools、util-linux 和 device-tree-compiler。将 `RAM_TRIAL_BASELINE_KERNEL` 设为原 Debian 内核路径。为每轮使用新的日志目录。下面的 `$virt_uboot`、`$virt_dtb` 是这个项目 `virt` 测试板的固件和设备树，`$bootaa64` 是原 EFI 分区中的 `EFI/BOOT/BOOTAA64.EFI`。

```bash
export RAM_TRIAL_VERSION=dev12.6
export RAM_TRIAL_BASELINE_KERNEL=/path/to/original/kernel.efi
bash tests/ram-handover/check-placement.sh
bash tests/ram-handover/efi-first.sh "$aavmf_fd" "$ram_bundle" "$virt_dtb" /path/to/new-edk2-log
bash tests/ram-handover/uboot-first.sh "$virt_uboot" "$bootaa64" "$ram_bundle" "$virt_dtb" /path/to/new-uboot-log
```
