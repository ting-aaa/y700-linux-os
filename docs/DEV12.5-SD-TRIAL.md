# 在国行 Y700 二代上试启动 dev12.5

试验卡装完整的 Debian 根文件系统和它自己的 EFI 分区。测试机现有 U-Boot 无法从卡槽读取启动程序，所以还需要在内置 EFI 分区添加一个菜单项和该项专用的三个文件。开机时从内置菜单选一次 **Y700 candidate (microSD)**。内核随后识别卡槽，核对根分区的标签、UUID 和系统身份，再从卡上启动 Debian。平时的默认项是 `debian.conf`。[独立镜像说明](DEV12.5-IMAGE.md) · [板级引导依据](BOARD-IMAGE.md#attended-candidate-03-tablet-gate)

## 在电脑上核对试验包

本地目录为 `out/dev12.5-sd-trial/`。先在 Linux 电脑上执行以下命令。解压需要至少 7,519,338,496 字节可用空间，目标文件名应为空闲路径。

```sh
sha256sum --strict -c TRANSPORT-SHA256SUMS
zstd -d y700-test-card.img.zst -o y700-test-card.img
sha256sum --strict -c SHA256SUMS
mkdir trial-entry
tar -xzf trial-entry.tar.gz -C trial-entry
(cd trial-entry && sha256sum --strict -c SHA256SUMS)
```

| 文件 | SHA-256 |
| --- | --- |
| 压缩卡镜像 `y700-test-card.img.zst` | `bc5d7e9b905c9bae6fb96572958989cea14c1ae6d5d1b3dc7e21ea4b49ce98f5` |
| 解压后整卡 `y700-test-card.img` | `4ccf7e3ec6f54fea3e80687a4115677c04bee4817c2f3ebe8077279696f67f7d` |
| 内置菜单补充包 `trial-entry.tar.gz` | `84ed9feab61162ce434b1d5ba2685de9ed0cb9ce10abb8ebead8b4cf6d635223` |

这份通用卡镜像保留首次触屏设密流程。需要为自己的平板预配蓝牙地址时，从同一版本的独立归档按机个性化解包，再生成卡镜像及对应清单。[个性化解包](DEV12.5-IMAGE.md#为一台平板准备蓝牙地址)

## 实机操作顺序

1. 准备一张已确认可整卡覆盖的备用 microSD，标称 8 GB 或更大。写入前核对实际字节容量、目标读卡器和卡。写入后读回前 7,519,338,496 字节，用上表中的**解压后整卡**摘要核对。测试机当前插着的卡已有一个分区。
2. 从工作正常的内置 Debian 运行 [试启动前检查](../tests/sd-trial-preflight.sh)。以 root 运行并在电脑上保存结果。脚本检查当前启动项、默认项、EFI 覆盖设置、UFS 来源、卡与内置文件系统的 UUID、四个目标文件的可用路径和 EFI 剩余空间。它还输出原始引导文件和运行内核的摘要。
3. 经机主确认后，将 `trial-entry` 下的 `EFI/y700-test/{kernel.efi,board.dtb,initrd}` 和 `loader/entries/y700-test.conf` 放到内置 `/boot` 下对应的新路径。放置时最后添加菜单项，读回全部四项与补充包清单核对。保留原来的 `loader.conf`、`debian.conf`、默认项和 Android 槽位。
4. 插入已校验的备用卡，在现场重启并在菜单里为本次启动选择 **Y700 candidate (microSD)**。用屏幕键盘设密、登录 Xfce。将已校验的 `verify-physical-boot.sh` 和 `identity.txt` 从电脑提供给本地会话，在同一目录执行 `sh verify-physical-boot.sh`。通过条件包括原生 EFI、正确的 PRC 板型和内核标识、同一物理 SD 上的根分区与 `/boot`，以及完整的 1,112 项软件包清单。[实机身份检查](../tests/verify-physical-boot.sh)
5. 正常重启并让菜单超时，回到内置 Debian。检查原 SSH 通道、桌面、内核摘要和引导文件。确认四个试验文件仍与试前清单相符后，先移除试验菜单项，再移除该项的三个专用文件。重新运行第 2 步，对比两次收集的原始引导文件和内核摘要。

## 卡缺失或系统不匹配时

仅试验菜单项选择专用的 `/y700-sd-trial-init`。它扫描合适的根分区最多 60 轮，每个未命中轮次等待一秒。找不到匹配卡，或只读核对时发现系统身份错误，它会发起重启。下一次开机让菜单超时即可进入默认的内置 Debian。这个回退需要内核仍能执行重启。平板目前没有向 Linux 注册硬件看门狗，整机卡死或启动菜单无法操作时仍需现场恢复。试验用 initramfs 在原文件后附加一个包含专用 init 的 cpio 归档。[Linux initramfs 格式](https://docs.kernel.org/driver-api/early-userspace/buffer-format.html) · [实机恢复能力](TABLET-LAB.md)

双盘 ARM64 虚拟机从模拟内置 EFI 分区选中试验菜单项后，用卡镜像的第二分区启动 systemd，并将卡的第一分区挂到 `/boot`。两者的逻辑扇区分别为内置盘 4096 字节、卡 512 字节。内核标识、1,112 项软件包和启动参数全部吻合。[双盘试验程序](../tests/board-image-vm.sh)

返回路径使用与当前平板逐项比对过的原版 EFI 加载器、默认配置、原内核和原 initramfs。两次独立的试验分别移除了虚拟卡，以及提供 UUID 正确但系统身份错误的卡。两次均由试验 init 发起重启，EFI 菜单在无人输入时选回 `debian.conf`。最小测试根文件系统的 PID 1 读回了这项 EFI 选择和原内核摘要，随后正常关机。虚拟机使用虚拟设备树；实机返回后的 Xfce、USB 和休眠恢复仍需分别验收。[返回测试程序](../tests/sd-trial-return/run.sh)
