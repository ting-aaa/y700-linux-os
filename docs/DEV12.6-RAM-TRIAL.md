# 在电脑上启动 Y700 dev12.6 内存桌面

本地目录 `out/dev12.6-ram-trial/` 中的五个文件包含完整通用 Debian 根文件系统、板型内核、设备树和启动参数。ARM64 QEMU 已用这份内核和 initrd 在无磁盘、无网络的虚拟机中完成触屏设置密码、LightDM 登录、进入 Xfce 和正常关机。实体平板另有一条 USB 内存测试路径，可以在现有内核上运行同一份根文件系统。

| 文件 | SHA-256 |
| --- | --- |
| `kernel.efi` | `4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1` |
| `board.dtb` | `1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d` |
| `initrd`（1,261,843,044 字节） | `ee4aceddc0302ff966c7d71f771e66302a50e83a3344e3f835e9a9cb40745946` |
| `cmdline.txt` | `7d640e2bae0dc9304858a8b65b32aa66476efeea16c148706281326ada86f294` |
| `SHA256SUMS` | `1bab4ba35ba8c351a1d7b3da90a77a9aa67601c1b60dc02fabdc205ed8a07db4` |

## 验证与运行

从仓库根目录运行。主机需要能运行 9 GiB 虚拟机的内存、ARM64 QEMU、AArch64 交叉编译器、uv 和设备树工具。`virt_dtb` 指向测试用 1024×768 虚拟板设备树（SHA-256 `a89bc8f2ee12f118656c6963fb9d45b862e6d5a1aeedf2630ddbe08f03079d31`）；包中的 `board.dtb` 对应国行 TB320FC_PRC 实体板型。[虚拟启动入口与工具变量](../tests/ram-trial/README.md)

```bash
set -eu
(
  cd out/dev12.6-ram-trial
  echo '1bab4ba35ba8c351a1d7b3da90a77a9aa67601c1b60dc02fabdc205ed8a07db4  SHA256SUMS' | sha256sum --strict -c -
  sha256sum --strict -c SHA256SUMS
)
RAM_TRIAL_VERSION=dev12.6 bash tests/ram-trial/run.sh \
  out/dev12.6-ram-trial "$virt_dtb" "$new_log_dir"
```

启动时，initrd 中的 SquashFS 持有完整 6 GiB ext4 文件。只读 loop 设备挂载两层文件系统，目录写入进入 tmpfs 上的 OverlayFS。测试在切换到 systemd 后确认，根目录中的临时写入仅出现在内存上层。首次密码和桌面资料随关机消失。

| 本次直接启动实测 | 结果 |
| --- | --- |
| 软件包 | 1,115 项，清单 SHA-256 `a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98` |
| 启动初期 | 外部磁盘 0，活动 swap 0，`/boot` 未挂载 |
| initrd 物理地址 | `0x48000000` 至 `0x93363264`（末端不含），与虚拟帧缓冲区无交叠 |
| 切换根文件系统后 | 内核报告总内存 9,151,256 KiB，可用内存 7,663,656 KiB |
| 触屏登录 | 通过 Type-B 触点输入；两次密码不一致时账户仍锁定，一致后由 Arctica 屏幕键盘完成普通用户 PAM 登录 |
| 会话与关机 | 同一个 seat0 本地 PAM 会话启动 Xfce，内核正常关机，QEMU 退出码 0 |

精简证据在 `out/dev12.6-ram-verified/direct-proof.log`，SHA-256 为 `d1f2fd5767cadd7d3e4dda894725d3c2b10dfda5f87380702a5bbdb69abd9796`。这次测量使用虚拟设备树和触摸屏。Board DT 随包交付；实机显示、触控与存储控制器的行为须在对应硬件验证。

## 在运行 Debian 的平板上从 RAM 验证桌面

在一台 16 GiB 国行 Y700 二代上，USB 用 33 秒将上述 1,261,843,044 字节的 `initrd` 传入平板的 tmpfs。平板核对了 initrd、SquashFS、6 GiB ext4 的 SHA-256，也核对了根文件系统中 1,115 项已安装软件包的版本和架构。当前运行的内核为 `7.3.4-asphalt-prc`。根文件系统的写入进入单独的 512 MiB tmpfs 上层。[内核 OverlayFS 文档](https://docs.kernel.org/filesystems/overlayfs.html)

镜像内的普通账户启动了 Xfce 窗口管理器、面板、桌面和 Onboard。测试使用 2560×1600 私有虚拟屏幕和 GTK 两倍缩放。Thunar 打开新建文件夹对话框后，Onboard 自动弹出。测试用虚拟指针点按五个字母键输入 `hello`，按回车确认，在内存上层找到了对应文件夹。对话框快捷键和回车均由测试程序产生。本轮使用平板 CPU 和原内核，实体玻璃触点、屏幕输出、GPU 和新内核仍需独立验证。[Thunar 文件夹操作源代码](https://github.com/xfce-mirror/thunar/blob/master/thunar/thunar-action-manager.c)

退出后，原系统的启动标识、当前桌面会话、锁屏状态、LightDM、SSH、NetworkManager 和蓝牙服务实例与测试前一致。临时文件、挂载和 loop 设备均已清理。缩减记录位于 `out/dev12.6-ram-verified/tablet-userspace.log`。复测需要已验证主机密钥的 USB SSH 连接，以及平板上已解包的 Debian ARM64 测试工具目录（含 Xvfb、xdotool 和 libxdo3）。[实机测试入口](../tests/ram-userspace/run.sh)

```bash
bash tests/ram-userspace/run.sh "$usb_ssh" out/dev12.6-ram-trial "$device_xvfb_usr"
```

另用当前平板的内核启动日志和 `/proc/iomem` 做了只读检查。8 个 CPU 在线，EFI 上报的中断属性表和 8 张 CPU 待处理表全部位于保留内存，共核对 9 张。旧内核向新内核交接和关机返回原系统的实机行为仍待验证。[EFI 交接测试](RAM-HANDOVER.md)

## 用现有通用镜像重新构建

输入目录中放入名为 `root.ext4`、`linux-boot.fat` 的两个普通文件。根文件取自重建的通用 dev12.6，SHA-256 为 `74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd`；FAT 取自 dev12.5，SHA-256 为 `495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6`。Linux 构建程序使用 mtools、squashfs-tools、GNU cpio 和 coreutils，以普通用户运行即可。[通用 dev12.6 根文件重建](ROTATION-IMAGE.md)

```bash
bash scripts/build-ram-trial.sh --dev12.6 "$images" "$new_output_dir"
```

构建程序会从 SquashFS 读出完整 ext4 并验证摘要，再检查附加到 dev12.5 板级 initrd 的启动脚本和 SquashFS 内容。本次压缩得到的 SquashFS 为 1,250,201,600 字节，SHA-256 为 `775a6da7210c47a73ca240c2114ba3349c6d9e3134df4aab3c17dd9a9131f3be`。使用默认参数重新构建 dev12.5 R2 后，五个文件逐字节匹配历史版本，包括 initrd 的 `88635b98e707fa1ba87d2f8e20b1fa1d5d00427c6ebf99c6ddfd833fc1d6e580`。测试还用两个已启动版本的记录交叉检查，确认选错版本时会拒绝相应库存。[构建脚本](../scripts/build-ram-trial.sh)
