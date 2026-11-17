# Driver research route

The owner explicitly requests open-source Snapdragon graphics drivers as the GPU reference, community research for other peripherals, and REA analysis/reconstruction where source information is missing. This is a development requirement, not a completed investigation.

## Graphics

Start from Linux DRM/MSM and Mesa Freedreno/Turnip, matching Adreno 730 / SM8475 and the actual firmware, DT, kernel, Mesa and compositor versions. Do not treat an Android emulator driver ZIP as a Debian native replacement.

- [Mesa Freedreno documentation](https://docs.mesa3d.org/drivers/freedreno.html) covers the driver stack and debugging entry points.
- [Mesa source](https://gitlab.freedesktop.org/mesa/mesa) contains Freedreno/Turnip, device information and change history; pin commits when evaluating changes.
- [Linux MSM driver source](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/gpu/drm/msm) is the kernel reference. Compare GMU, power, preemption, IOMMU and scheduler behavior against the measured failure rather than assuming Mesa alone is responsible.
- [Mesa GPU tracing](https://docs.mesa3d.org/u_trace.html) provides a tracing route for a later controlled workload.
- The upstream [Turnip developer presentation](https://archive.fosdem.org/2024/events/attachments/fosdem-2024-2033-turnip-update-on-open-source-vulkan-driver-for-adreno-gpus/slides/22737/Update_on_Open_Source_Vulkan_Driver_for_Adreno_gqrqgmC.pdf) documents A730/A740 work; it is supporting history, not proof that this tablet's full stack works.

Record a hypothesis table with source evidence and a minimal discriminating test. Use captured failure logs and PC analysis while unattended. Do not trigger the known GPU hang on the only working tablet when no one can recover it physically.

## Other devices

Identify exact compatible strings, bus IDs and component revisions before borrowing code. Start with the pinned Asphalt tree and [lenovo-basements/lenovo-sm8475-mainline](https://github.com/lenovo-basements/lenovo-sm8475-mainline), then relevant Linux subsystem maintainers, linux-msm, postmarketOS and upstream issue/patch discussions. Same SoC is a useful clue, not proof of identical wiring, calibration, firmware or power sequencing.

For sensors, distinguish accelerometer, gyroscope, magnetometer and any sensor hub; establish their actual transport and driver interfaces before adding an orientation daemon. For touch/audio/Bluetooth/power, trace the complete DT → firmware → kernel → userspace path and test suspend/reconnect behavior as well as initial probe.

## REA when needed

Use REA's shipped-artifact analysis workflows after identifying a specific unresolved interface: original driver module, firmware, HAL/service or configuration. Record artifact hashes, origin, imports/exports, strings, protocols and observed runtime behavior. Keep private binaries/captures local; publish only reviewed findings and code with clear provenance and applicable licenses.

Recovered behavior must become a documented specification, an implementation candidate and a repeatable comparison/test. Decompiler output or plausible register guesses alone are not a working driver. Do not attempt to load an Android vendor kernel module into an unrelated mainline kernel as if its ABI were portable.
