# 国行 Y700 的 UFS 时钟与电源协调候选

2026-11-22，在 dev12.13 默认 60/120 Hz 内核上移植了社区的 UFS / ICE 时钟与 CX、MX 电源域变更。原发行镜像保持原版本。候选在电脑完成两次独立 ARM64 链接、PRC 设备树校验和 QEMU 无盘内核启动。平板上的 UFS 链路、耗电、读写和睡眠唤醒仍待验证。

## 先前故障与本次范围

11 月 21 日的日用 dev12.11 日志先后记录了电池服务读取超时（启动后 7296.313 秒）、WCN6855 固件 RDDM（7310.752 秒）和 CPU0 soft lockup（7320.991 秒）。多次堆栈停留在 ath11k DMA unmap / ARM SMMU TLB 同步。到 7954.919 秒 UFS Hibern8 退出才报告 `-ETIMEDOUT`，随后 PHY 校准与控制器重启失败，两层 ext4 进入只读。另一次恢复启动 6482 秒时两层 ext4 已可写、各自错误计数为零。一次 UFS 逻辑单元复位与后续健康描述符提供了恢复后的状态，故障时的实际 ICE 时钟和 CX/MX 电源级别仍未知。[故障时序与恢复记录](CAMERA-FOCUS-PROBE.md)

这份候选检验存储电源切换这一条具体假设。早于 UFS 报错的 Wi-Fi 固件和 SMMU 异常仍需独立调查。代码所改的是升降频时序、电源约束和驱动对所设频率的记账，实机事件之间的因果关系和功耗变化尚无测量。

## 发行版与候选的差异

从正式 dev12.13 解包的 EFI FAT（SHA-256 `cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d`）读取默认加载项和 `/EFI/debian/board.dtb`，得到板树 `53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7`。该树已经使用 SM8475 turbo 兼容串和 75/850 MHz 两级 OPP。缓存内核源通过社区 0032 PHY 表、0033 binding、0034 turbo、0035 OPP 四个补丁的严格反向校验。社区新版树测试在原树的八个时钟名称处如期失败。[原 Asphalt 队列](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/series.nix) · [新队列](https://github.com/dianqk/nixos-android-devices/blob/21d4a113ac49892723986a843bb2ce6942567d62/pkgs/linux-kernel/sm8475/asphalt/series.nix)

| 项目 | dev12.13 默认 | 实验候选 |
| --- | --- | --- |
| UFS 主控时钟 | 8 个，AXI 和 UniPro 随 OPP 切换 | 保留原 8 个 ID，在末尾加入 ICE core，三者一起选择 75 或 850 MHz |
| GCC 父电源域 | RPMh CX | RPMh CX 和 MX |
| ICE 初始状态 | 设备树未指定初始频率及电源级别 | 显式以 75 MHz 和 LOW_SVS 初始化 |
| 主控制器的性能下限 | 固定 NOM，同时有两级 OPP | 由 75 MHz 的 LOW_SVS（64）和 850 MHz 的 TURBO_L1（416）OPP 投票 |
| 初始化时钟 | 获取各时钟时可能先设置最大值，再应用 OPP | 对 OPP 主控先获取全部句柄，然后经 OPP 框架依次设置电源与时钟；每个成功的频率写入更新该时钟的当前值 |

直接采用 dianqk 提交 `21d4a113ac49892723986a843bb2ce6942567d62` 选择的两份上游补丁。0036 改动 SM8475 DTSI 和 3 个 binding，另一个共享补丁改动 UFS 核心。当前编译配置内建 UFS、QCOM 主机与 PHY、GCC、RPMh 和 ICE。现有 QCOM 时钟公共驱动会挂接设备树的电源域列表，GDSC 对每个父域建立子域关系。[上游提交](https://github.com/dianqk/nixos-android-devices/commit/21d4a113ac49892723986a843bb2ce6942567d62) · [初始化顺序补丁](https://github.com/dianqk/nixos-android-devices/blob/21d4a113ac49892723986a843bb2ce6942567d62/pkgs/linux-kernel/patches/ufs-opp-init-order.patch)

## 已验证的产物

| 工件 | SHA-256 |
| --- | --- |
| `kernel.efi` | `243db9c43ef8f7a4a3e224106d87f2c87ba16c1ce93c475c4eafa02f8817fce6` |
| `board.dtb` | `c2def1dcb64e3a50fbad8304ffbb92c34401c03bf4b3a72471799b6dab75c65c` |
| `notes` | `96f7f8fa58c211d1eee65be0084c4048f4c6244d843e7ae487788ad7356e382a` |
| 三文件 `SHA256SUMS` | `3bbd18ba67ad1700eeca55485121269871e24743c0fe9fe569a541c7af9a8361` |

两个私有 overlay 从相同缓存树出发，先重建出与发行版逐字节相等的完整内核和 DTB，再移植 UFS 改动。两次候选的三份工件也逐字节相同。明确强制编译了 `ufshcd.o`、`ufs-qcom.o`、`gcc-sm8450.o`、`gdsc.o`、`ice.o` 并核对 AArch64 ELF；内核配置、release 和导出符号清单与原树相同。

社区的 `asphalt-ufs.py` 验证了所有九个时钟名称、OPP 向量、ICE 初始频率和 RPMh 实际提供者。我们另行反转九个发生变化的属性，将整棵排序后的 PRC DT 与正式树比对至完全相等，改动无关的型号字段会被拒绝。dtschema 2026.9 检查三个 binding 及其示例，板 DT 的指定 schema 验证没有诊断输出；去掉第二个 GCC 父域后，真实 validator 报告 `power-domains ... is too short`。QEMU `virt` 使用候选 Image 和独立内存 initrd 启动，读回了与工件一致的运行内核 notes 后正常关机；该虚拟机没有物理 UFS 控制器。[社区检查](https://github.com/dianqk/nixos-android-devices/blob/21d4a113ac49892723986a843bb2ce6942567d62/tests/asphalt-ufs.py) · [全树比对](../tests/ufs-scaling/check-board.sh) · [无盘启动](../tests/ufs-scaling/boot-smoke.sh)

## 复建与下一步实机诊断

在 Linux 主机使用常规 GitHub CLI 的只读权限取得七个小文件。构建器需要原项目已编译的内核缓存、正式 EFI FAT、LLVM、mtools、dtc、uv，以及 PATH 中同一 uv 环境的 dtschema 和 yamllint。所有临时内核写入都位于私有 overlay。输出目录须为新路径。[取源](../tests/ufs-scaling/fetch-inputs.sh) · [输入摘要](../tests/ufs-scaling/inputs.sha256) · [构建器](../tests/ufs-scaling/build-candidate.sh)

```bash
bash tests/ufs-scaling/fetch-inputs.sh "$new_inputs"
uv venv --python 3.12 "$new_tools"
uv pip install --python "$new_tools/bin/python" 'dtschema==2026.9' yamllint
sudo env "PATH=$new_tools/bin:$PATH" "UV_BIN=$(command -v uv)" \
    bash tests/ufs-scaling/build-candidate.sh "$prepared_kernel" "$new_inputs" "$release_esp" "$new_output"
bash tests/ufs-scaling/boot-smoke.sh "$new_output" "$busybox_arm64" "$new_log"
```

下一次有授权的硬件比较应记录普通启动与候选运行时 notes、设备树、UFS devfreq、当前 AXI/UniPro/ICE 频率、RPMh 可观察的投票、运行时电源状态和 UFS 错误计数。通过已知只读数据的有界读取、空闲及再次读取，比较首次恢复延迟，并记录 `ufshcd_clk_scaling` 和 `ufshcd_uic_command` 可用事件。应分别记录主机运行时省电、链路 Hibern8 和整机深睡，只有完整观察到的转换才算对应资格。现有完全无盘诊断 DT 已禁用 UFS，无法测到这条链路。试验内核和板树应从独立入口共同加载，并保留正式启动项和现场恢复条件。
