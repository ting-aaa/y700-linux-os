# Sanitized physical baseline

On 2026-11-17 the owner authorized installation with Android retaining approximately 64 GiB and Debian approximately 385 GiB. The experimental system subsequently booted to Debian 13.7 ARM64 / Xfce 4.20 from internal UFS using `7.3.4-asphalt-prc`.

Boot chain: vendor ABL → B-slot PRC U-Boot → UFS FAT ESP/systemd-boot → Linux/initramfs/DTB → ext4 Debian root. Do not reuse an earlier temporary-trial procedure that restores Android A after every test; this is now a permanent Linux install. Android system A was retained, but its user data was cleared during the authorized partitioning.

## 2026-11-18 repairs and observations

- Installed 25 missing packages for the terminal, network GUI, authentication agent, xinput and OpenSSH; subsequently added four screen-keyboard accessibility/tooling dependencies and one time-sync package. Package dependency/audit checks passed.
- Replaced the failing USB status-only gadget with a tested ACM + NCM composite configuration. Windows drivers enumerated successfully; strict host-key checked SSH reached the installed Debian root.
- Chromium launch was associated with `GMU OOB GPU_SET timeout`, `gpu fault`, `hangcheck recover`, offending task `xfwm4:gdrv0` and later `preemption timed out`. Current mitigation disables Xfwm compositing and Chromium GPU rendering. User confirmed usable browser windows and successful website access afterwards; hardware acceleration remains unresolved.
- The original network chooser was not discoverable. Increased panel/icon sizes, enabled Onboard for Xfce and added missing accessibility dependencies. User confirmed keyboard input. A later chooser showed only the current network although scanning returned other APs; direct named activation in a local password prompt succeeded. No password was captured in agent output.
- A phone hotspot passed association, DHCP, DNS, 12/12 gateway probes and three HTTPS requests over Wi-Fi. This short sample does not establish long-term stability or throughput.
- Portrait touch mapped correctly. `xinput map-to-output` after left rotation produced matrix `0 -1 1; 1 0 0; 0 0 1`; the owner confirmed corner taps, window dragging and keyboard positions. Saved the Xfce rotation and installed a session watcher; new-login/cold-boot persistence remains untested.
- NTP synchronized after installing and enabling the time service. B slot remained active, successful and bootable at final readback.

This report is a reduction of private local logs and owner observations, not an independently repeated public lab test. Raw serials, host keys, SSIDs, IP addresses, personal paths, device snapshots and private backups are deliberately excluded. New product tests must generate their own sanitized evidence bound to candidate commits.
