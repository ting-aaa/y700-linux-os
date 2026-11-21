# 国行 Y700 的 UFS 时钟与电源协调候选

2026-11-22，在 dev12.13 默认 60/120 Hz 内核上移植了社区的 UFS / ICE 时钟与 CX、MX 电源域变更。原发行镜像保持原版本。候选在电脑完成两次独立 ARM64 链接、PRC 设备树校验和 QEMU 无盘内核启动。随后两版内核在同一台国行平板完成了本文末尾的只读对照：进入运行时挂起与 Hibern8 后，均能唤醒并读回相同内容。耗电、带写入的长期稳定性和整机深睡仍待验证。

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

实机比较分别核对运行内核 notes、板树、UFS devfreq、AXI/UniPro/ICE 频率、运行时电源状态和 UFS 错误计数。日用内核另有跟踪事件和电源域摘要。两次 RAM 观测均间隔 12 秒再读；读取后的系统恢复与整机深睡分开验证。

## 从独立 RAM 环境观测

这台板的私有 v2 位于 `out/ufs-scaling/observer-v2/initrd`，6,988,579 字节，SHA-256 `71d078d6490152ccbab7efacaa1251c18ef6e3a2757f70fa07fc460fda2730e7`，两次完整交叉编译、封装结果一致。它同时支持上面的两版内核。PID 1 核对运行内核 notes、PRC 与板上 UFS 节点的时钟数。包内有一份静态 AArch64 程序、已核验的七个 PMIC/UCSI 模块和 26 个 ADSP 固件文件、这台板私有的分区匹配输入。分发源码，硬件准备时从本机已核对的输入生成私有产物。首版 `out/ufs-scaling/observer/initrd`（`380711f0…`）及源码 `0e51a36` 保留供复核。[构建入口](../tests/ufs-scaling/build-observer.sh)

```bash
bash tests/ufs-scaling/build-observer.sh out/dev12.12-ram-receiver/initrd \
    .local/ufs-trial-partuuid "$new_private_directory"
```

启动参数要求 `rdinit=/init y700.ufs_observe=1 noresume`；板端使用配对的内核与保留 UFS、禁用 microSD 的 PRC DT。内核枚举设备和 GPT 后，观察程序通过 `BLKROSET` 给已出现的实物块设备及分区设置本次启动的只读策略，随后每 250 ms 检查新出现的节点。程序仅挂载内核伪文件系统。指令入口是 USB ACM `Y700_UFS_OBSERVER`，其余没有 shell、网络接口配置、块文件系统挂载、udev、swap 或包管理。主机端显式选择端口和预期版本。0 是原版、1 是候选。[采集工具](../tests/ufs-scaling/collect.py)

```powershell
uv run --with pyserial python tests/ufs-scaling/collect.py --port COM<n> --variant 0 --output stock-receipt.txt
```

发出读取请求后，程序按 UFS 主控拓扑、GPT 分区号 41、`boot_b` 名称、196,608 个 512 字节扇区和私有 GUID 限定对象。只读打开同一父设备，核对主 GPT 头 CRC、第 41 项与内核报告的起点和长度；显式读取的 GPT 元数据是两个逻辑扇区。两次对分区偏移零 `O_DIRECT` 读取 65,536 字节并验证 SHA-256 `4316fe356d9244f97b0623abc1e6fc820b295738af24fbe0f3a0f82482d07cad`。中间板端空闲 12 秒。确认父 LUN 已完成写请求数及能读到的错误计数无变化。回执只发读耗时、状态和计数，启动数据及 GUID 留在本地。[定位和读取](../tests/ufs-scaling/observer-storage.c)

四组数值分别在第一次读取之前、第一次之后、空闲结束、第二次之后取得。`RANGE` 给出 devfreq 当前允许上下限与可用 OPP 范围，不应用日用系统的限频规则。`PHASE` 中的 runtime 为 0 活动、1 已挂起、2 正挂起、3 正恢复、4 不支持；link 为 0 OFF、1 ACTIVE、2 HIBERN8、3 BROKEN、4 UNKNOWN。`-1` 表示接口没有提供该数值。时钟是 Linux CCF 对三个分支的频率记账值，link 是驱动记账状态。单次采样可能略过中间切换，耗时只覆盖 `pread`。这条试验不进行吞吐压测，不启用 tracing，也无法测出电源轨上的电压、电流或证明进入系统深睡。[采样实现](../tests/ufs-scaling/observer-io.c)

主机先保存并校验数字回执，再用摘要 ACK。已开始的操作可以用 `--resume` 取回缓存，设备不会为回放再读分区。正常 ACK 或等待命令约 105 秒到期后会请求重启；独立 PID 1 另有从用户态启动算起的 155 秒上限。若内核整体停止调度、控制器在内核关机阶段锁死，仍需现场恢复。此软件计时器没有硬件 watchdog 保证。[PID 1](../tests/ufs-scaling/observer-init.c)

v2 在 QEMU 里也执行板端使用的 ConfigFS 建立步骤，创建配置字符串、ACM 函数及其绝对路径链接。虚拟机使用 virtio 串口传输回执。单独将链接恢复成首版的相对路径后，同一 stock 内核返回 `UFS1 EARLY_EXIT 64`。原版和候选内核均内建 ACM；两份发行来源的 DT 分别有 8 和 9 个 UFS 时钟，PRC 检查通过。观察程序在离开前向控制台写 `UFS1 SUPERVISOR N`，向本次内核日志写 `UFS1 EARLY_EXIT N`。40–46 表示无法打开对应模块，50–56 表示加载失败（顺序见代码），60 是未出现 UDC，61–65 分别是配置目录、描述符、函数、链接、绑定，68/69 是端口打开或属性失败。两份 DT 中都没有声明 ramoops 设备，重启后无法保证从日用系统找回该日志。[ACM 初始化](../tests/ufs-scaling/observer-port.c)

PC 在两个真实内核上均从相同 initrd 启动，以 320 MiB ARM64 QEMU、virtio 串口和一份可写的合成 GPT 文件验证正常读回、保存、ACK 与重启。GUID 错误、缺少 `boot_b`、只检查且原始设备仍可写都在分区数据读取前拒绝。已知前缀故意损坏在第一次读后拒绝。每次测试后比对整份虚拟磁盘字节。无主机命令的单独测试覆盖超时返回。该虚拟机缺少 UFS、PRC USB/电源硬件，故所有对应的时钟及错误接口报告 `-1`。各项数值收据位于 `out/ufs-scaling/observer-verified/`。[QEMU 正反例](../tests/ufs-scaling/observer-vm.sh)

## 日用内核的只读基线

参考平板的 dev12.11 在正常桌面运行时，UFS 主控和 UniPro 均为 75 MHz，ICE 为 300 MHz。板内 udev 规则将 `max_freq` 设为 75 MHz。驱动列出的两个可用频率分别为 75 和 850 MHz。自动 Hibern8 的配置为 150,000 µs，时钟门控延时为 150 ms。

三次间隔三秒的 `O_DIRECT` 读取各取 `boot_b` 起始 65,536 字节，逐次核对电脑上已封存的板级 U-Boot 前缀。包含启动读取程序及 SHA-256 的耗时分别为 10,980、19,707、13,253 µs。独立 tracefs 实例在整个窗口记录了六对 Hibern8 进入与退出请求及对应完成事件、三次运行时挂起和三次恢复。内核报告零跟踪丢失、零新增 UFS 错误，逻辑单元复位维持为一，主机复位及命令中止为零。日用系统当时也可以主动访问存储，事件计数代表整个窗口。日志为 `out/ufs-scaling/daily-read.log`，SHA-256 `7e4c8dda9453c29b5f73baa5d1d49b73b7b51cf4bc7b2bfb2bd1b3f848c1ed6f`。[采样脚本](../tests/ufs-scaling/observe-daily.sh)

## 从正常 Linux 数据分区暂存并启动观测器

`prepare-stage.sh` 核对两版内核与原板树，只改动两棵树的 microSD 状态。它生成两个内核、两棵小板树和一份私有 initrd；同卷支持硬链接时直接复用输入。将这五个经验证的文件放入经分区标签与私有 PARTUUID 识别的 Linux 数据分区顶层 `/y700-ufs-observer/`，目录权限 0700。使用空的新目录，结束后按原清单核对并移除这五个临时文件。固件默认启动项始终指向原日用系统。

```sh
bash tests/ufs-scaling/prepare-stage.sh "$stock_image" "$stock_board_dtb" "$candidate_dir" "$private_initrd" "$initrd_sha" "$new_cache"
uv run --offline tests/ufs-scaling/stage.py check "$new_cache" stock "$initrd_sha"
uv run --offline tests/ufs-scaling/stage.py check "$new_cache" candidate "$initrd_sha"
```

主机在获准的单轮试启动前先启动 `stage.py boot "$new_cache" stock "$initrd_sha" --linux-partuuid "$private_linux_partuuid"` 等候串口，再从空闲日用系统正常重启。候选使用 `candidate`。U-Boot 只从该分区的固定路径读入三件工件，核对各自的长度、RAM 地址和 CRC、板型、UFS 启用与 microSD 禁用状态，最后发出一次启动请求。原有无盘相机工具继续要求两个存储控制器均已禁用。

用真实 ARM64 QEMU U-Boot 和含校验和及 orphan file 特性的 ext4 测试盘，两套输入都通过。错误分区 UUID 和错误文件 CRC 均被拒绝，可写的合成整盘在固件读取前后 SHA-256 相同。首个平板对照试启动同样通过了 U-Boot 的三项 RAM 校验，USB 观测口未出现，平板自动返回日用 dev12.11。复机后两层 ext4 直接读回通过，临时文件清理完成。随后在独立、未绑定 USB 控制器的 configfs 测试目录内复现了旧程序的相对链接失败；使用绝对目标路径创建 ACM 链接成功。[U-Boot 对照测试](../tests/ufs-scaling/stage-qemu.py) · [固件加载入口](../tests/ufs-scaling/stage.py)

## 实机对照结果

两次独立的 RAM 启动使用相同的 V2 观测程序、相同分区和相同的两段只读操作。两棵树均启用 UFS、禁用 microSD，运行内核的 notes 分别对应原版和候选。同一次启动内读两次相同的 64 KiB，间隔 12 秒。两次内核启动均未设置日用系统的 75 MHz 上限，devfreq 可用范围实读为 75–850 MHz。

| 单次试验 | 工作时 AXI / UniPro / ICE | 空闲时 AXI / UniPro / ICE | 首次直接读 | 空闲后直接读 |
| --- | --- | --- | ---: | ---: |
| 原版 dev12.13 | 约 850 / 850 / 300 MHz | 75 / 75 / 300 MHz | 545 µs | 10,342 µs |
| 社区候选 | 约 850 / 850 / 850 MHz | 75 / 75 / 75 MHz | 496 µs | 16,164 µs |

这是内核时钟框架在板上的读数；高档实际报告 849,999,902 Hz。等待后的采样中，两版主机都处于 runtime suspended、链路 Hibern8；第二次读取后都回到 active。两个样本均匹配封存引导文件的前缀 SHA-256。每轮观测期间，目标父块设备的内核写入计数无变化，十项 UFS 错误合计为零，逻辑单元复位维持为一，主机复位与命令中止均为零。一个读延迟样本不足以比较吞吐或判定性能变化。

此结果确认候选的 ICE 变频路径在板上生效。此前 Wi-Fi、SMMU 和 UFS 在混合负载下先后报错的原因仍未确定。此次采样没有测量功耗或验证整机深睡。日用系统另一次独立采样中，Linux 通用电源域 `cx` 报告 on/256、`mx` 报告 off-0/0；这是软件投票汇总，实际物理电压仍需测量。两轮均正常返回原 dev12.11 内核，1,248 个包、四项服务及两层 ext4 的写入同步和直接读回均通过。主机随后核对并清理了数据分区的五个暂存文件。

原版及候选收据的 SHA-256 分别为 `b9c7f3e1d0cb25e5000c9739f5514c4102fced6eec3a169d268d21636fa5d6df` 和 `8567156cbc635c19c3fab14a1fea316ba274a7a73e79c26d1e70647c59afea3c`。[原版数值收据](../tests/ufs-scaling/physical/stock.txt) · [候选数值收据](../tests/ufs-scaling/physical/candidate.txt)
