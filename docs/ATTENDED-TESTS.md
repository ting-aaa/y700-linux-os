# Next attended acceptance window

These are pending tests, not instructions for unattended execution. Preserve the known working system until the owner can operate the tablet and a recovery route is checked. No test is passed merely because the PC build or CI succeeds.

## Preconditions

Record the exact candidate/source/firmware hashes, power level, host tools and rollback files. Confirm the actual external backup medium and manifest; an offline disk is not a missing backup. Verify recovery access before a kernel/boot/lifecycle test. Keep the current installed configuration and maintenance credentials separately; the new package changes the USB identity and authentication policy. Stop at the first loss of access, unexpected power event or driver fault.

## Test sequence

| Stage | Procedure and acceptance | Rollback / unresolved prerequisite |
| --- | --- | --- |
| Existing desktop persistence | First verify saved landscape, touch corners/dragging and keyboard after one logout/login; only then one controlled cold boot. Record all four orientations separately. | Preserve current Xfce config and touch helper; user must be available for display failure. Repeated-cycle qualification follows only after this first check. |
| Candidate maintenance policy | On a recoverable candidate, authenticate the newly generated host key, verify USB enumeration, successful allowed-user login, denied wrong key/source, and no Wi-Fi listener. | Restore prior userspace config via the independent verified recovery route. Do not test by disabling the only active access path. |
| Touch-only desktop | At login and in terminal/browser/settings: show keyboard, type, hide it, discover a different Wi-Fi network, connect without the host entering credentials, and use system actions. | Current console-only enrollment and login keyboard gaps must be implemented first; package presence is not a pass. |
| Sensors | After native SSC/firmware integration, list actual sensor names/revisions; sample accel/gyro at rest and controlled movement. Start rotation bridge in observe mode, then test all four directions and manual lock. | Preserve registry/calibration; restore original userspace packages/config without reseeding calibrated state. Live SLPI integration may require recovery. |
| GPU hypothesis isolation | Use the fixed input table, baseline workload and one changed factor per boot. Capture first-error ordering and stop on first fault. | Original boot entry/kernel/firmware must be restorable; no unbounded crash-recovery loop. Preemption-off is a hypothesis, not a default fix. |
| Other hardware | Audio at safe low volume, microphone, Bluetooth input/audio, Wi-Fi reconnect, display brightness and Type-C roles independently. | Exact component/interface inventory first; no unsupported firmware substitutions. |
| Lifecycle qualification | Only after stable individual tests: declare cycle counts, workload duration, thermal limits and recovery criteria in the candidate test record before testing. Exercise update interruption and rollback on recoverable media first. | Full recovery and update rollback are still not demonstrated. Do not retroactively lower criteria to pass a candidate. |

PC work can continue independently: lock and reconstruct the complete base image, complete first-boot/credential handling, build native SSC packages, compare PRC firmware interfaces, and prepare signed update/rollback artifacts. Stable image publication remains gated on real device evidence.
