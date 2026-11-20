# Y700 二代的电源键与 RTC 唤醒路径

TB320FC_PRC 的原 Debian 内核已经注册电源键，并提供 `s2idle` 和 `deep`。已交付的设备树沿用 PMK8350 RTC 的 `disabled` 默认值，因此当前系统缺少硬件定时唤醒设备。电脑上已用原源码编译两份独立 DTB，并验证可沿用 dev12.8 已安装的 RTC 驱动。平板的清醒状态检查中，成功和失败的系统睡眠计数均为零。电源键唤醒、RTC 唤醒以及唤醒后的屏幕、触控、Wi-Fi 和 USB 恢复均待实测。[平板清醒状态与桌面策略](STATUS.md#wake-sources-on-the-running-tablet)

## 从硬件到 Linux

| 来源 | 板级接线和驱动 | 已确认的行为 |
| --- | --- | --- |
| 短按电源键 | PMK8350 的 PON 子设备，`KEY_POWER`，SPMI SID 0、外围号 `0x13`、位 7，双边沿 | 板级 DTS 已启用此键。内置的 `pm8941-pwrkey` 对 Gen3 电源键默认启用唤醒，挂起回调在 `device_may_wakeup()` 成立时调用 `enable_irq_wake()`。回调忽略该调用的返回值。清醒时注册成功仍不足以证明固件睡眠后能返回。 |
| RTC 定时闹钟 | 同一 PMK8350，计数器和闹钟的外围地址分别为 `0x6100` 和 `0x6200`。闹钟 IRQ 为 SID 0、外围号 `0x62`、位 1，上升沿 | `rtc-pm8xxx` 在成功分配并请求 IRQ 后，将它注册为系统唤醒 IRQ，向 RTC 核心发布闹钟。原树禁止该节点，平板当前没有 `/dev/rtcN`。 |

两者共用 SPMI 仲裁器的 `periph_irq`。子 IRQ 的 `irq_set_wake` 将请求传给这条父 IRQ。SM8450/SM8475 的 DT 用高电平 PDC 输入 1，按首个映射范围 `<0 480 12>` 对应 GIC **SPI 481**，即 INTID 513。运行中分配的 Linux IRQ 号可不同。PDC 驱动把线路启用与父 GIC 配置联动。电源域和固件在真实睡眠期间的行为仍需测量。[SoC 设备树](https://github.com/torvalds/linux/blob/v7.3/arch/arm64/boot/dts/qcom/sm8450.dtsi) · [SPMI 仲裁器](https://github.com/torvalds/linux/blob/v7.3/drivers/spmi/spmi-pmic-arb.c) · [Gen3 电源键](https://github.com/torvalds/linux/blob/v7.3/drivers/input/misc/pm8941-pwrkey.c)

原内核有 `CONFIG_SUSPEND=y`、PSCI CPU idle 及电源域支持，`CONFIG_HIBERNATION` 关闭。清醒时读到 `/sys/power/state = freeze mem` 和 `mem_sleep = [s2idle] deep`。s2idle 可在系统冻结后依靠已配置的中断唤醒。深度挂起还依赖平台进入与退出，当前 PSCI 驱动会查询固件的 `SYSTEM_SUSPEND` 能力。菜单或 sysfs 出现 `deep` 不能验证外设恢复或待机耗电。[Linux 系统睡眠](https://docs.kernel.org/admin-guide/pm/sleep-states.html) · [PSCI 实现](https://github.com/torvalds/linux/blob/v7.3/drivers/firmware/psci/psci.c)

## 与 Android 的交叉核对

在电脑上合并 CN350 固件已选定的 `vendor_boot` DTB 第 2 项与 DTBO 第 14 项。合并后的 `/soc/qcom,spmi@c42d000/qcom,pmk8350@0/rtc@6100` 可用，兼容串、两段寄存器和闹钟 IRQ 均与 Linux 原树相同。厂家 PON 子节点同样是 `qcom,pmk8350-pwrkey`、键码 116 和 `<0 0x13 7 3>`。另用这台平板此前留存的 CN350 运行时 FDT（765,677 字节，SHA-256 `bda4b80b9cb73e1b001cf22666890ad0139f0246e08a86d432a190d8e06ba4c6`）独立核对，RTC 节点同样启用且只有 compatible、interrupts、phandle、reg 和 reg-names 五个属性。这为恢复 Linux 的节点提供了本机型号的依据。Android 的服务用 wake lock 和 SystemSuspend 协调休眠，Debian 使用 logind/Xfce 策略和 Linux PM 核心。工厂配置没有给出本机当前 RTC 的 UTC 偏移或本次固件运行时的 IRQ 所有权。[Android SystemSuspend](https://source.android.com/docs/core/power/systemsuspend) · [上游 PMK8350 定义](https://github.com/torvalds/linux/blob/v7.3/arch/arm64/boot/dts/qcom/pmk8350.dtsi)

## 独立 DTB 与模块

| 本地文件 | 改动 | SHA-256 |
| --- | --- | --- |
| 封存镜像的 `board.dtb` | 板级基准，121129 字节 | `1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d` |
| `out/rtc-dtb-candidate/board.dtb` | 仅将 RTC 状态设为 `okay` | `2b15b316054e66993dd31ff51752ecbb8fa166e83688c5d2cc54189e420eed95` |
| `out/rtc-dtb-candidate/probe-rtc1/board.dtb` | 启用节点，并为其指定 `/aliases/rtc1` | `501e44f89c639165aa753ecbb336d14ac38846abdfc57cc343806a3248844e51` |

构建器先从准备好的 7.3.4 Asphalt 树重建原 DTB，并核对全部字节。然后重新编译所选候选，用独立的 `fdtput` 修改原始副本，对两棵完整树排序后逐属性比较。缩减收据位于 `out/rtc-dtb-candidate/verification.log`，SHA-256 为 `b1b0b44e11092ef44dffc088fed05e7f785da2f195e279d20969fe8bb4ecc11c`。相同输入重复编译得到相同字节。构建在电脑的新目录内进行。[构建脚本](../scripts/build-rtc-dtb.sh)

```sh
bash scripts/build-rtc-dtb.sh "$prepared_kernel" "$new_status_candidate"
bash scripts/build-rtc-dtb.sh --probe-rtc1 "$prepared_kernel" "$new_clock_probe_candidate"
```

原内核配置 SHA-256 为 `a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56`。从同一树的独立写时复制视图重新编译 `rtc-pm8xxx.ko`，剥离调试信息后与 dev12.8 封存根中解压的模块逐字节一致，SHA-256 为 `707db597ed3f2f23dcf82bdff76c3706c16b989eba9ff447b0435dc80be972c8`。镜像内原始压缩模块 SHA-256 为 `3400560df16bd304fe76e7049f6ee9d5273e3e19bc23497ab95f6a7c83eef184`，含 `qcom,pmk8350-rtc` 模态别名。启用节点无需替换模块。[类似设备对同款 RTC 的板级启用](https://github.com/torvalds/linux/blob/v7.3/arch/arm64/boot/dts/qcom/qcm6490-fairphone-fp5.dts)

## 首次注册与系统时间

原配置将 `RTC_HCTOSYS_DEVICE` 与 `RTC_SYSTOHC_DEVICE` 都设为 `rtc0`。注册名匹配时，RTC 核心读取设备并调用 `do_settimeofday64()`，驱动延后加载也会触发。NTP 向硬件写时另按 `SYSTOHC_DEVICE` 选择目标。清醒的 Debian 当前运行 systemd-timesyncd，报告已同步，chrony 未运行。本机 PMIC 计数的实际纪元和 Android 校时源仍待测量。[RTC 注册逻辑](https://github.com/torvalds/linux/blob/v7.3/drivers/rtc/class.c) · [NTP 写 RTC](https://github.com/torvalds/linux/blob/v7.3/kernel/time/ntp.c)

PMK8350 的驱动探测会尝试设置 `0x6146` 的启用位，读取秒数使用 `0x6148` 起的四字节小端计数。写闹钟使用 `0x6240`，启用位在 `0x6246`、清中断在 `0x6248`。两个候选均沿用原树，无 `allow-set-time`、NVMEM offset 或 `qcom,uefi-rtc-info`。在这种配置下读取的偏移为零，设置 RTC 时间的路径会返回 `ENODEV`。注册时仍会读取已有的硬件闹钟。首次探测前不应假定 PMIC 时间等于系统 UTC，也不应将 Android 时钟偏移写入未知存储。[RTC 驱动](https://github.com/torvalds/linux/blob/v7.3/drivers/rtc/rtc-pm8xxx.c)

专用探测树为将来的隔离唤醒验证保留 `rtc1`。在只绑定这一个 RTC 的早期环境中，注册前检查 RTC 类为空，核对最终 DT 的 `rtc1` 指向目标 PMIC，随后核对注册设备的 OF 路径、`hctosys=0`、RTC 读数和独立的系统时间。编号已占用时，RTC 核心会退回到可用编号。无法保证独占的环境可另编隔离测试内核，关闭 `CONFIG_RTC_HCTOSYS` 和 `CONFIG_RTC_SYSTOHC`。这两项均为编译配置。探测树只针对内核按名称进行的校时，显式调用 `hwclock` 的用户空间程序仍能访问指定设备。[RTC sysfs 接口](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-rtc)

在电脑上用原内核 `9afa9b69…`、512 MiB ARM64 QEMU 和测试专用 PL031 模块运行两个无盘对照。每次先将来宾系统时间设为 2024-01-02，再注册计数为 2010-01-02 的模拟 RTC。普通编号得到 `rtc0/hctosys=1`，系统时间跳至 2010。探测别名得到 `rtc1/hctosys=0`，系统时间保留在 2024，同时仍可读到 2010 的 RTC 时间。两次均正常关机，可用下列命令复测。虚拟 PL031 验证的是共同的 RTC 核心。平板的 PMIC 响应、中断归属、唤醒耗时和待机电流仍需独立实测。[无盘对照脚本](../tests/rtc-alias/run.sh)

```sh
bash tests/rtc-alias/run.sh "$prepared_kernel" "$static_arm64_busybox" "$new_logs"
```
