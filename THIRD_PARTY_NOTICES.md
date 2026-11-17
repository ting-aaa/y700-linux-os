# Third-party notices

Project-owned integration code and documentation use the root MIT license. External components retain their own terms; the root license does not relicense Linux, U-Boot, Debian packages, firmware or device-tree source derived from other projects.

The Asphalt board recipes derive from and refer to `dianqk/nixos-android-devices` at the commit in `upstream.lock.json`. Its top-level MIT notice is preserved at `licenses/asphalt-upstream-MIT.txt`. Individual source files and patches may carry separate notices that must remain intact when fetched or redistributed.

Kernel/U-Boot sources and firmware binaries are not vendored in this initial public import. Their full license/source obligations must be reviewed before binary release. Debian package metadata and the firmware acquisition recipe are inputs to that review, not a blanket grant to redistribute every captured blob.
