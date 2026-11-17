# PC implementation and verification receipt

Date: 2026-11-18. This records a development milestone, not release acceptance.

| Check | Result and scope |
| --- | --- |
| Platform package | Two builds byte-identical; safe packaged file modes, no shared identity, no automatic service enablement |
| Repair archives | All 30 exact archives matched; tampered, missing and extra archives rejected |
| ARM64 integration | Copied the unchanged historical base into a new private directory, installed all repair archives plus the platform package; dpkg audit empty and APT dependencies satisfied |
| ARM64 runtime checks | SSH syntax and effective policy, host-key persistence, systemd unit validation and Onboard settings round-trip passed under QEMU user emulation |
| Clock seed | Candidate seed advanced to the fixed build epoch; no host/tablet clock changed, no new NTP-on-hardware claim |
| Provisioning/orientation | Five unit-test methods passed, including invalid-input and four-orientation cases, debounce/unknown/lock behavior and failed-mapping retry delay |
| Sensor registry | Two pinned builds produced 385 identical files; upstream Linux sensor/registry suite passed 10 tests |
| Public source | Staged text/syntax/import-provenance scan and Bash syntax passed locally; CI separately reports its own result |
| Tablet | Read-only kernel/Mesa/firmware/sensor/service observations only; existing LightDM, SSH and USB maintenance remained active |

Builder evidence: dpkg-deb `1.23.7` on amd64, qemu-aarch64 `10.2.1`, uv-managed Python 3.12 on Linux and 3.13 on Windows. The development package `y700-platform_0.1.0~dev1_all.deb` SHA-256 was `a0616d5b8cfbc0b8c5fa029429e26a3d6e3383f6bd8348abcd4db441ef3f74a7` with `SOURCE_DATE_EPOCH=1794960000`. It remains a local build artifact; no stable binary release was uploaded.

The initial install correctly failed because the package reused an Onboard-owned filename. The corrected package owns `y700-onboard.desktop` instead. Subsequent validation exposed synthetic NTFS permissions; the builder now assigns explicit modes and regression-checks them. Integration uses a fresh temporary archive directory per invocation so a prior build's extra package cannot bypass the supplied lock. These corrections were tested rather than treating the first attempt as success.

The host systemd verifier warns about the distribution's existing `!!` modifiers in networkd/timesyncd units. It accepts the two new units. An earlier test reported missing `XDG_RUNTIME_DIR`; the current check supplies a private runtime directory. Neither warning is presented as hardware evidence.

No new kernel, complete bootable image, native libssc binary, graphical session, SSH authentication exchange, USB enumeration, GPU workload, sensor samples, suspend/resume or full recovery was tested. Codeberg source retrieval timed out; that external dependency remains open. The complete Debian base content/package lock, private identity finalization and firmware provenance still prevent a clean-checkout product-image claim.

Raw logs and candidate roots stay private. The current installed tablet was not updated, rebooted, logged out, re-partitioned or flashed. The original validation workspace and backups were not modified.
