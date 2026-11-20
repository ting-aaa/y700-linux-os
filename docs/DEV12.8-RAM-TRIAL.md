# dev12.8 临时内存桌面

本地目录 `out/dev12.8-ram-trial/` 中的五个文件组成一套可丢弃的 Debian 桌面。内核从 initrd 中的只读 SquashFS 打开完整的 6 GiB ext4，用户文件、密码和设置写入 RAM 的临时上层。内存试用采用与 dev12.8 完整镜像相同的 1,124 项软件包清单。[完整镜像](ADAPTIVE-BRIGHTNESS-IMAGE.md)

| 输入或产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| 封存通用 `root.ext4` | 6,442,450,944 | `2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511` |
| initrd 内的 SquashFS | 1,253,445,632 | `d4af2501573b90778c1dffb2006c6a6c338960625dfc80625a59154703bda278` |
| `initrd` | 1,265,087,076 | `c2c0375bbdae3fb2ae0b1dcc6ac44e549cfc194eacc6e80e6b3925bce254579f` |
| 五文件目录内的 `SHA256SUMS` | 304 | `ee630ed892e415b0d4bc75145e61f885444c45b32101ca6fe599dd06d753d458` |

## 在电脑上运行

需要 ARM64 QEMU、可分配给来宾的 9 GiB 内存、静态 AArch64 交叉编译器、dtc、uv 和项目验证过的 QEMU 虚拟设备树。运行目录须尚未存在。

```bash
(cd out/dev12.8-ram-trial && sha256sum --strict -c SHA256SUMS)
RAM_TRIAL_VERSION=dev12.8 bash tests/ram-trial/run.sh \
    out/dev12.8-ram-trial "$virt_dtb" "$new_log_dir"
```

两次独立开机均在无磁盘、无网卡、无活动 swap 的 ARM64 虚拟机中完成。每次均从锁定的初始账户开始，使用虚拟 Type-B 触点拒绝不一致的密码、设置新密码、通过 LightDM/PAM 进入普通用户 Xfce 会话。普通用户的自动亮度客户端已启动，设置为关闭。测试在用户主目录留下一个文件并正常关机，第二次启动确认该文件和上次的密码状态均已清除。第一次开机检查时，来宾可用内存约 7.3 GiB。

从完整镜像解包所得的两个普通文件 `root.ext4` 和 `linux-boot.fat` 可直接作为构建输入。构建会从 SquashFS 读出完整 ext4 重新校验，并核对追加进 initrd 的两个成员。默认 dev12.5 和 `--dev12.6` 的历史构建入口均已复跑，输出五个文件各自与相应封存版本逐字节相同。[构建脚本](../scripts/build-ram-trial.sh)

```bash
bash scripts/build-ram-trial.sh --dev12.8 "$images" "$new_bundle"
```

## 从原内核切换到内存桌面

电脑上的 ARM64 QEMU 已跑通 dev12.8 的完整切换。U-Boot EFI 先启动平板原 Debian 的内核，测试程序移除虚拟启动盘，通过独立的虚拟串口传入封存的后继内核和完整的 1,265,087,076 字节 initrd。原内核核对摘要并装载三个内存段，实际段位均避开虚拟板的四张活动中断表。新内核接管后，在没有外部磁盘和活动 swap 的情况下启动。来宾核对了 1,124 个软件包，通过虚拟触屏设置密码、登录普通账户的 Xfce，随后正常关机。

测试只在交给第一个内核的虚拟设备树中加入标记。新内核同时读到了该标记和内核交接标志。试验前后封存文件的校验结果一致。平板上的只读检查也确认其九张活动中断表均在内核保留区内。实机能否完成同样的内核切换，以及切换后实体面板和 USB 能否恢复，仍待验证。[实机保留区与设备树](RAM-HANDOVER.md)

复测使用平板原 Debian 的 EFI 内核、项目固定版本的 QEMU U-Boot、EFI 启动程序及虚拟板设备树。缩减记录 `out/dev12.8-ram-handover/uboot.log` 的 SHA-256 为 `96031d2fc39a1e88be093dd0fdf5841d6471e0b15f1f111d15755df6b34e2e3d`。

```bash
RAM_TRIAL_VERSION=dev12.8 RAM_TRIAL_BASELINE_KERNEL="$baseline_kernel" \
    bash tests/ram-handover/uboot-first.sh "$virt_uboot" "$bootaa64" \
    out/dev12.8-ram-trial "$virt_dtb" "$new_log_dir"
```

## 平板原内核上的隔离桌面

平板通过 USB 接收同一份 initrd，校验载体、完整 ext4 和运行时 1,124 个已安装包。测试沿用正在运行的 `7.3.4-asphalt-prc` 内核，在独立的挂载、进程、网络和 IPC 命名空间中运行普通账户 Xfce。根文件系统由只读镜像和 tmpfs 上层组成。Xvfb 提供 2560×1600、200% 的私有显示，测试进程只能访问私有 D-Bus 和虚拟指针。[实机验证入口](../tests/ram-userspace/run.sh)

```bash
bash tests/ram-userspace/run.sh "$usb_ssh" out/dev12.8-ram-trial "$device_xvfb_usr"
```

`usb_ssh` 是已锁定平板主机密钥的 USB SSH 脚本。`device_xvfb_usr` 是设备上已经解包的 Debian ARM64 测试工具目录，需包含 Xvfb、xdotool 和 libxdo3。测试开始前检查无活动 swap、至少 8 GiB 可用内存和至少 3 GiB 可用 `/run` 空间。实体面板、背光、传感器及实际座席的交互仍需分别验收。

最终实机回归用 33 秒传输 1,265,087,076 字节。在同一次私有桌面会话中，两项操作均通过。

- 从已安装的桌面入口打开平板亮度设置，用私有指针将自动亮度从关闭切至开启再关闭。两次均独立读回普通账户的临时偏好，并在开启时看到等待环境光传感器的提示。
- 用 Thunar 的新建目录对话框调出 Onboard，确认 2560×840 键盘窗口可见，再点击屏幕键盘的五个字母。目录 `hello` 创建成功，且只存在于临时上层。

测试前后的启动标识、座席、锁屏状态、服务实例、背光请求值、根与启动挂载、swap 和 SLPI 状态一致。退出码为 0，临时挂载和 loop 均已清理。完整无盘启动由电脑上的两次独立开机验证，平板上的验证沿用原内核。实机缩减记录 `out/dev12.8-ram-verified/tablet-userspace.log` 的 SHA-256 为 `2d09679fccdcc5a9fead0dce0014618a5b174ac8c6771f29de728ece909787dd`。

较早的实机尝试逐次保存在 `out/dev12.8-ram-verified/native-controls.log`。前两次通过 Thunar 输入，分别在测试环境缺少私有系统总线、镜像缺少 `gtk-launch` 时停下。第三次停在键盘窗口枚举。第四次独立记录了 X11 枚举时的 `BadWindow` 和键盘几何匹配失败。最终测试按 GTK 的会话总线名识别实际进程，通过 X11 窗口 ID 单独核对键盘的映射与尺寸。完整验证记录可在 `out/dev12.8-ram-verified/` 用 `sha256sum --strict -c SHA256SUMS` 复核。
