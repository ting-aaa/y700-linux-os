# dev12.11 无线固件与 UFS 故障时序

原故障启动的 8 个 ARM64 栈各有 4 个来自 ath11k 的 PCI copy-engine 接收和 4 个来自 monitor-ring 定时器。两路都已经从 SMMU 同步调用返回到恢复中断的位置。第一次 Wi-Fi 固件崩溃通知比第一次电池服务超时晚 14.440 秒，第一次 UFS Hibern8 退出超时又比这条通知晚 644.167 秒。现有记录无法确定哪项硬件最先失效。[同次启动记录](CAMERA-FOCUS-PROBE.md#kernel-fault-evidence)

### 原版内核指令

用原故障内核 `out/camera-gt9768-final/kernel.efi` 验证。其完整 SHA-256 为 `b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625`。用带符号的本地参考 ELF 定位三个不含跨函数跳转的指令段，在原始 Image 中分别找到唯一匹配（52、44、56 字节），再解码原始 Image 自己的分支目的地。[发行内核身份](USB-AUDIO.md)

- 4 个 CE 栈的返回地址为 `ath11k_ce_per_engine_service+0x178`，4 个定时器栈为 `ath11k_dp_rx_process_mon_status+0x3ec`。两处前一条 `bl` 都指向 Image 偏移 `0x14b888` 的 DMA unmap。WCN6855 的 `rxdma1_enable=false`，普通 MAC 启动就启用此 monitor-status 定时器。定时器样本不能证明当时开启了用户抓包、额外扫描或相机业务。[驱动启动流程](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/net/wireless/ath/ath11k/mac.c) · [定时器](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/net/wireless/ath/ath11k/dp_rx.c)
- 8 个栈都报告 `arm_smmu_tlb_sync_context+0xa8`。前一条 `bl` 在 Image 偏移 `0xbabfa4`，调用 `_raw_spin_unlock_irqrestore`。8 个被打断的 PC 都为后者 `+0x28`，对应 `mrs x8, sp_el0`，落在锁释放和中断屏蔽恢复之后。各次 TLB 同步是否耗尽轮询、持续多久，现有栈都没有测到。该构建关掉了 Qualcomm 专用 TLB 超时诊断。[SMMU 同步](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c)

以下命令可直接在电脑复核原始 Image 的两段指令。

```sh
k=out/camera-gt9768-final/kernel.efi
sha256sum "$k"
aarch64-linux-gnu-objdump -b binary -m aarch64 -D --start-address=0xbabf9c --stop-address=0xbabfac "$k"
aarch64-linux-gnu-objdump -b binary -m aarch64 -D --start-address=0x16d9510 --stop-address=0x16d9524 "$k"
```

### 哪些记录能证明恢复

CPU0 在 7320.991 秒报告的 `23s` 是两次 `running_clock() >> 30` 读数之差，每格约 1.074 秒。按该 printk 时间近似反推，上一次 watchdog 刷新约在 7295.2–7297.4 秒，与 7296.313 秒开始的电池超时相近，早于 7310.752 秒的 RDDM **通知**。这给出了调度进展的时间范围，无法定位固件故障发生的瞬间。[watchdog 计时](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/kernel/watchdog.c)

驱动先打印 RDDM，再检查重复事件和设备卸载状态，满足条件才将 reset 排入工作队列。7380.385 秒的 `failed to start hw scan: -110` 属于扫描启动路径。判断驱动是否走到 mac80211 重配置成功，可在已保存的同启动完整内核日志中检索 `pdev [0-9]+ successfully recovered`。这条消息在检查 `ATH11K_STATE_RESTARTED` 后发出，接着驱动唤醒队列。原故障的筛选摘录没有保留这条记录。恢复后主会话通过 USB 只读核对，设备日志只保留当前一次启动，搜索 RDDM 和恢复消息都为零。原启动的恢复结果已无法从当前 journal 核实。[RDDM 回调](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/net/wireless/ath/ath11k/mhi.c) · [mac80211 重配置完成](https://github.com/torvalds/linux/blob/f24ba334afafc70c3149e9db9c0cf8ecc6d52a09/drivers/net/wireless/ath/ath11k/mac.c)

逐行比对 Asphalt `8dcb481f` 与 `21d4a113` 的板级补丁列表，仅新增两项 UFS 改动。两版的 SMMU 补丁 0024 内容相等，特殊页表与故障处理按 `qcom,sm8450-iris-secure-arp` 绑定到视频解码器 ARP 上下文。WCN6855 的 PCIe 上下文使用原路径。新板树在独立 RAM 试验中测得 ICE 降频及 UFS 读回；该试验没有复现原无线事件，不能据此认定原故障已修复。[原 Asphalt 队列](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/series.nix) · [新队列](https://github.com/dianqk/nixos-android-devices/blob/21d4a113ac49892723986a843bb2ce6942567d62/pkgs/linux-kernel/sm8475/asphalt/series.nix) · [0024 限定条件](https://github.com/dianqk/nixos-android-devices/blob/21d4a113ac49892723986a843bb2ce6942567d62/pkgs/linux-kernel/sm8475/asphalt/patches/local/0024-qcom-smmu-secure-arp.patch) · [UFS 试验](UFS-SCALING.md)

本地证据位于 `out/camera-optical-qa/board-{first-events,onset,recovery-stacks,wifi-sequence,storage-recovery}.txt`。原始寄存器、用户数据和无线数据包均无需读取。
