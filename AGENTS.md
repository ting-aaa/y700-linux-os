# Y700 Linux OS development

- Use uv for every project Python invocation and environment.
- This directory is the product repository. The earlier local validation workspace is separate and must not be imported wholesale or initialized as this repository.
- Read README.md, docs/STATUS.md, docs/PRODUCT.md and docs/BUILD.md before changes. If available, read ignored local context in `.local/` and `.project-memory/` for device access and the current handoff.
- Keep evidence boundaries explicit: source change, static check, clean build, QEMU test, physical test, user confirmation, release acceptance. Never substitute one for another.
- Treat the reference build recipes as historical experimental inputs. Integrate and validate them before using them as a release pipeline.
- Keep secrets, raw device captures, serials, personal network details, user backups and proprietary firmware blobs out of commits and public issues. Publish reduced evidence, provenance, checksums and source instructions instead.
- Prefer reusable configuration/packages and reversible updates over one-off commands. Every device modification needs a rollback path and versioned evidence.
- For package-only work, apply the reviewed package directly to the connected Debian tablet, verify the affected package and running services there, and keep image inputs in sync. A separate image boot or image regression run is not a gate for package-only changes.
- For an owner-authorized unattended trial of an independently staged kernel, use the [tablet lab](docs/TABLET-LAB.md). Verify the counted entries, finite retry budget, and return to the known default. These trials may run while the owner is away. Preserve the original kernel, initramfs, bootloader and Android partitions. Changes to GPT, the bootloader or those original artifacts require their own recovery plan and authorization.
- While the owner is away, prioritize PC builds, static analysis, QEMU, read-only remote diagnostics and reversible userspace fixes that preserve the known working USB channel. A disconnected device is a reason to continue PC work, not to keep interrupting the owner.
- Do not enable the known failing GPU workload unattended. Software rendering is a workaround, not GPU acceptance.
- Do not disable browser sandboxing, thermal protection or authentication to manufacture functionality. Do not invent hardware success or make unmeasured performance claims.
- Review the exact staged tree before every public push. Preserve upstream licenses and avoid inherited private Git identities.
