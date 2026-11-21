# dev12.10 主摄供电候选 ESP

## dev12.11 主摄与 RTC1

dev12.11 的发行 FAT 为 1,073,741,824 字节，SHA-256 为 `92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36`。它选用带 GT9768 的内核及同时启用 PMK8350 RTC 的设备树。板级 RTC 固定为 `rtc1`，内核的启动校时和回写目标均为 `rtc0`。构建先将仅含主摄改动的板级树重新编译到已审核哈希，再增加 RTC 的 `status = "okay"` 和 `rtc1` 别名。构建器对整个设备树做语义比对。[清醒闹钟实测](SUSPEND-ROUTING.md)

```sh
bash scripts/build-camera-ldo5.sh --lens "$PREPARED_KERNEL" "$work/lens"
bash scripts/build-rtc-dtb.sh --gt9768-rtc1 "$PREPARED_KERNEL" "$work/combined"
cp "$work/lens/kernel.efi" "$work/lens/notes" "$work/combined/"
bash scripts/build-camera-esp.sh --gt9768-rtc1 "$dev1210_fat" "$work/combined" "$work/linux-boot.fat"
```

| 组件 | SHA-256 |
| --- | --- |
| 板级内核 | `b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625` |
| 组合设备树 | `53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7` |
| 运行内核 notes | `35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6` |
| 根中的 `rtc-pm8xxx.ko.zst` | `3400560df16bd304fe76e7049f6ee9d5273e3e19bc23497ab95f6a7c83eef184` |

两次独立重建得到相同 FAT，只有内核和板级树两个文件变化。仅启用 GT9768 的变体使用 `build-camera-esp.sh --gt9768`，输出哈希为 `5004039ac64b91a5dc70375cb0db6c11aff590dcb69031dd5c767323f1e90d40`。组合模式拒绝仅启用主摄的树、错误的内核 notes 和错误的来源 FAT。

完整发行 TAR 解包后，ARM64 虚拟机用包内内核、原 initrd 和 dev12.11 根启动到 systemd。来宾匹配了全部 1,240 个已安装软件包及内核 notes，加载了包内 PMK8350 RTC 驱动，随后正常关机。虚拟机使用其专用设备树。平板的真实睡眠和唤醒需要在实机测量。[发行包](DEV12.11-IMAGE.md)

## dev12.10 供电修复

这份 1 GiB FAT32 分区镜像用于从 dev12.10 通用根启动带 HI1339 辅助供电的内核。默认入口仍是 `loader/entries/debian.conf`，其内核命令行仍选择 `root=PARTLABEL=linux`。这套介质需要同一发行包中的 `root.ext4` 和板级 U-Boot。日常平板已安装的文件根使用独立 EFI 入口。

| 本地交付文件或配套输入 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `out/dev12.10-camera-esp/camera-supply-candidate.fat` | 1,073,741,824 | `ecdc35608c24b06cbad557f724ada12d7f3c98dbc92143a2e8c6d562ca9b7b67` |
| `out/dev12.10-camera-esp/camera-supply-candidate.fat.zst` | 80,306,563 | `b646f4e2ecde0b9425a211d9eedb0d1c9d994d9ccb4985f06779da95ef8dda0c` |
| dev12.10 原始 `linux-boot.fat` | 1,073,741,824 | `495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6` |
| 配套 `root.ext4` | 6,442,450,944 | `18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd` |
| 配套 `asphalt-prc-u-boot.img` | 41,406,464 | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |

## 离线构建

在 Linux 电脑上准备原始 dev12.10 发行 TAR、`mtools`、`dosfstools`、`util-linux` 和 GNU coreutils。内核产物可取自板级供电构建器输出目录，或从已验证的 `ldo5-entry.tar.gz` 提取。生成 FAT 的步骤使用普通用户和常规文件。示例中的 `$repo` 和 `$work` 均为绝对路径。[dev12.10 发行包](DEV12.10-IMAGE.md) · [LDO5 内核构建器](../scripts/build-camera-ldo5.sh)

```sh
set -eu -o pipefail
cd "$work"
release=y700-tb320fc-prc-debian-dev12.10
tar -xOf "$repo/out/dev12.10-board/$release.tar" "$release/base/linux-boot.fat.zst" |
    zstd -dq --sparse -o release.fat
tar -xf "$repo/out/dev12.10-ldo5-trial/ldo5-entry.tar.gz" entry/EFI/y700-ldo5-12-10
bash "$repo/scripts/build-camera-esp.sh" release.fat entry/EFI/y700-ldo5-12-10 camera-supply-candidate.fat
zstd -q -T1 -8 -c camera-supply-candidate.fat >camera-supply-candidate.fat.zst
```

构建器固定输入、输出哈希与 FAT 写入时间。它在同一目录内准备临时文件，检查两侧文件系统、目录树及每个文件后才创建输出。原 FAT、候选 FAT 均含 11 个常规文件。仅 `EFI/debian/kernel.efi` 和 `EFI/debian/board.dtb` 两个文件内容变化。其余九个文件包括原启动管理器、两个 Android 工具、原 initrd、四个 BLS 入口和菜单配置。[ESP 构建器](../scripts/build-camera-esp.sh)

## 启动验证

复现使用既有的 `tests/board-image-vm.sh`。在新的 QA 目录内准备 `root.ext4`、`asphalt-prc-u-boot.img`、候选 FAT（命名为 `linux-boot.fat`）和原 `identity.txt` 的副本。仅在这份供测试程序读取的清单中，将 `kernel_notes_sha256` 设置为 `b52f0aebff47c2d1819d4569abc6f27d9c2f274f60f0230365d3440f99416fc7`，然后用 `sha256sum asphalt-prc-u-boot.img linux-boot.fat root.ext4 identity.txt >SHA256SUMS` 记录输入。从仓库执行以下命令。

```sh
UV_PYTHON=/usr/bin/python3 UV_OFFLINE=1 bash tests/board-image-vm.sh \
    "$qa_inputs" "$board" "$qemu_bundle" "$new_vm_dir"
```

ARM64 QEMU 经 U-Boot 和默认 EFI 入口启动了候选内核。原 initrd 启动了封存根中的 systemd，校验通过 1,240 个包的完整清单，随后正常关机。虚拟机专用 FAT 副本使用了虚拟板设备树、串口观察参数和观察脚本。完整介质清单、独立重建与启动收据见本地 `out/dev12.10-camera-esp/VERIFICATION.txt`。板上真实读取到的 GT9768 标识和 EEPROM 校验来自使用同一内核与设备树的单次试启动。该通用 FAT 与配套根的实体冷启动仍待验证。[启动夹具](../tests/board-image-vm.sh) · [实机范围](CAMERA-FOCUS-PROBE.md)
