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

旧内核的板级设备树和 dev12.6 包内设备树逐字节相同，SHA-256 为 `1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d`。树中有一个 GICv3 和一个 ITS 节点。既有的原系统实机日志记录了 U-Boot EFI 2.11、`MEMRESERVE`、一张属性表和八张 CPU 待处理中断表。实机 U-Boot 装在 Android boot v2 容器中，针对 SM8475 的引导接口和外围设备构建。这次虚拟机测试覆盖虚拟板上的 EFI 和内核交接。平板自己的中断表保留区、显示、触控、USB、休眠与断电后返回原系统，需要分别验证。本地摘要记录在 `out/dev12.6-ram-handover/board-record.log`，SHA-256 为 `6f68661260e87a4fbbdd943770249e78a41433d2b1503fe0475f6be0939dad00`。

## 在 Linux 电脑上复测

准备可运行 QEMU AArch64 的主机、uv、Python 3、ARM64 静态 C 编译器、GNU cpio、mtools、util-linux 和 device-tree-compiler。将 `RAM_TRIAL_BASELINE_KERNEL` 设为原 Debian 内核路径。为每轮使用新的日志目录。下面的 `$virt_uboot`、`$virt_dtb` 是这个项目 `virt` 测试板的固件和设备树，`$bootaa64` 是原 EFI 分区中的 `EFI/BOOT/BOOTAA64.EFI`。

```bash
export RAM_TRIAL_VERSION=dev12.6
export RAM_TRIAL_BASELINE_KERNEL=/path/to/original/kernel.efi
bash tests/ram-handover/check-placement.sh
bash tests/ram-handover/efi-first.sh "$aavmf_fd" "$ram_bundle" "$virt_dtb" /path/to/new-edk2-log
bash tests/ram-handover/uboot-first.sh "$virt_uboot" "$bootaa64" "$ram_bundle" "$virt_dtb" /path/to/new-uboot-log
```
