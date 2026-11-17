# Product objective and acceptance

Deliver a maintainable native Linux desktop for the Y700 2023 that works without another computer for ordinary use and uses the device hardware through supported, measured drivers. Debian remains the starting userspace; changing the desktop stack requires a reasoned comparison and a reversible prototype, not another blind installation.

## Priorities

1. **Reproducible baseline and recovery:** turn inherited scripts and live repairs into versioned packages/overlays, parameterized builds, input locks and an evidence-producing pipeline. Preserve the known working install and independent USB maintenance route.
2. **Complete everyday desktop:** discoverable networking, touch keyboard at login and in applications, settings, terminal, notifications, file/device management, permissions, localization, input methods and accessibility. Investigate the network chooser that omitted scanned networks.
3. **Hardware enablement:** investigate the observed GMU/Adreno hang first. Map firmware/kernel/Mesa/compositor interactions. Inventory sensors, wire orientation changes to display and touch together; validate audio, Bluetooth, video and external I/O.
4. **Power and reliability:** charging, thermal limits, suspend/wake, idle consumption, disconnect/reconnect and recovery after failures.
5. **Distribution and lifecycle:** install/upgrade/rollback design, signed manifests and updates, per-device secrets, supported firmware/model matrix, reproducible release notes and end-user documentation.

## Release gates

| Gate | Required evidence |
| --- | --- |
| Build | Fresh checkout + declared external inputs produce images; exact tool/source/package versions and hashes recorded; no reliance on developer home paths |
| Boot/recovery | Repeated physical boot and update failure/recovery scenarios on the supported device configuration; rollback actually demonstrated |
| Desktop | Touch-only path through first boot, login, network selection, browser, files, settings, update and power actions; secrets remain private |
| Hardware | Per-function tests on real hardware, including sustained GPU workloads and sensors; unsupported functions explicit |
| Power | Repeated suspend/resume and charge/discharge tests, thermal safety, measured idle and sustained-load behavior |
| Security | Unique credentials/host keys; no shared production root key; least-privilege services; authentication and browser sandbox retained |
| Delivery | Source/license/SBOM review, checksummed artifacts, signed release metadata, upgrade/rollback instructions and known limitations |

Before declaring a release candidate, define numerical duration/cycle/performance criteria and run them on the exact candidate. Do not retroactively reduce criteria to label a failed candidate successful. Hardware constraints or unavailable proprietary components must be reported, not hidden behind a claim of complete support.

## Work without an attending owner

PC-side builds, QEMU tests, source research and read-only diagnosis can proceed independently. Preserve USB access during any reversible userspace work. Kernel changes, boot trials, forced GPU reproduction, firmware replacement, reboot/suspend, storage changes or operations that may need physical recovery wait for an attended test window. If disconnected, continue useful PC-side tasks and record the exact next hardware gate.
