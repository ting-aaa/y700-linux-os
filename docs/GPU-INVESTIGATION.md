# Adreno 730 investigation — 2026-11-18

The failure is unresolved. No acceleration workload or GPU register/debugfs capture was run on the unattended tablet during this investigation.

## Fixed evidence

Historical failure sequence: GMU `GPU_SET` acknowledgement timeout, GPU fault/hangcheck involving `xfwm4:gdrv0`, then preemption timeout. The first reported GMU timeout preceded the recorded Chromium start; timing alone does not identify the first causal fault. Current software rendering is a temporary usability measure.

Fresh read-only inspection: kernel `7.3.4-asphalt-prc`; `libgl1-mesa-dri` and `mesa-vulkan-drivers` `25.0.7-2+deb13u1`; `libdrm2` `2.4.124-2`; `msm.enable_preemption=-1`. LightDM and the existing USB/SSH services remained active. The kernel source examined is the local build input with the pinned Asphalt queue, not a claim that running memory was compared to every source byte. [Input hashes](research/gpu-inputs.json) distinguish source files from installed firmware.

Primary implementation references: [Linux DRM/MSM](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/gpu/drm/msm), [Mesa Freedreno documentation](https://docs.mesa3d.org/drivers/freedreno.html), [Mesa 25.0.7 source](https://gitlab.freedesktop.org/mesa/mesa/-/tree/mesa-25.0.7/src/freedreno), and the exact [Asphalt kernel queue](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/series.nix). Website access to the Mesa source was unavailable in this session; no Mesa source rebuild or exhaustive change-history comparison is claimed.

## Source findings and hypotheses

| Hypothesis | Supporting/limiting evidence | Discriminating next test |
| --- | --- | --- |
| GMU power handshake/runtime-PM ordering | `a6xx_gmu_set_oob()` requests an interrupt acknowledgement and waits 10 ms per poll attempt; it can wait for a pending fault dump before retrying. `hw_init()` aborts if `GPU_SET` fails. This is a handshake failure, not evidence that merely increasing a timeout fixes the cause. | Attended trace correlating runtime PM, first IOMMU/GPU fault and GMU OOB, using exact unchanged firmware/Mesa inputs. Avoid register reads while power is off. |
| A7xx preemption/ring transition | A730 catalog entry enables the preemption quirk; auto (`-1`) selects four rings in `a6xx_gpu_init()`. Historical recovery ends in preemption timeout, which might be cause or consequence. | Separate attended boot candidate with `msm.enable_preemption=0`, same workload/input set, then restore original boot configuration. Compare first error and elapsed workload, not just whether a desktop appears. |
| Firmware/board-version mismatch | Driver names SQE `a730_sqe.fw`, GMU `gmu_gen70000.bin`, ZAP `a730_zap.mdt`; installed SQE/GMU hashes recorded. PRC and upstream ROW baselines differ. A filename does not prove semantic compatibility. | Complete ZAP/DT/firmware provenance comparison against supported stock versions on PC first. Do not replace firmware unattended or mix unrelated device ZAP files. |
| Mesa submission/compositor trigger | Compositor and browser activity overlap failure. Installed Mesa is known; no API trace or source-level reproducer yet. | With recovery available, separate compositor-only, OpenGL and Vulkan tests, then browser. Change one Mesa build at a time. Preserve sandboxing. |
| IOMMU fault preceding GMU timeout | OOB source explicitly handles an in-progress fault dump; historical fault ordering needs full monotonic reconstruction. | Analyze complete existing journal/coredump metadata locally; on an attended failure collect first-fault evidence before recovery obscures ordering. |

Two shortcuts are rejected from the actual source:

- **Blindly disabling IFPC:** the inspected `0x07030001` A730 catalog entry has no `ADRENO_QUIRK_IFPC`; initialization already chooses `GMU_IDLE_STATE_ACTIVE`. This does not disable every power transition, but an IFPC-off patch is not an established change to this configuration.
- **Changing the live preemption parameter and declaring an A/B test:** ring count is selected during GPU initialization. Writing the variable on the running driver does not recreate those rings. This test requires a separate attended boot/module initialization plan, not an unattended sysfs write.

The Asphalt queue already contains five GMU sync-state patches. Do not reapply a similarly titled patch without checking the actual source. Upstream itself records an unexplained GMU timeout and partial GLES support in its [pinned hardware status](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/docs/asphalt/status.md); that is corroborating context, not this tablet's diagnosis.

## Attended experiment contract

Before testing, preserve the currently working boot entry/root state, verify USB recovery independently, and record kernel/DT/module/firmware/Mesa hashes plus the exact command/environment. Run baseline and one changed candidate, with a stop condition on the first GPU fault or maintenance-channel loss. Restore the baseline before trying another factor. Define sustained workload duration and repeat cycles before collecting release evidence. No candidate in this document is accepted as a fix.
