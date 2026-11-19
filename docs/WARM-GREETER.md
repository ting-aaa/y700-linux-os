# Optional touch sign-in

The warm-greeter layer selects Arctica on LightDM seat0 and defaults its embedded Onboard keyboard to visible. Use it for ordinary sign-in after the local account has a password. The first password prompt is managed by the separate tty1 enrollment layer.

Arctica 0.99.9.4 starts Onboard in its supported XEmbed mode. The tested Debian 13 ARM64 configuration includes Metacity and uses Onboard's Compact layout and Nightshade theme. [Arctica greeter source](https://github.com/ArcticaProject/arctica-greeter/blob/0.99.9.4/src/arctica-greeter.vala)

## Build and install into a private image

The layer adds 35 Debian archives and one local configuration package to the 994-package dev5 base. The Debian archives were independently matched with signed Trixie metadata. The layer lock also pins the bytes of the locally built configuration package.

An offline ARM64 install produced 1030 installed package tuples without replacing an installed package. The seat0 configuration and compiled Onboard default were verified with LightDM and GSettings. Purging the two greeter packages from a disposable overlay restored the stock output of `lightdm --show-config` and passed the package audit.

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
  --lock config/warm-greeter-debian-auth.lock.json --cache /build/warm-greeter-debs
bash scripts/build-warm-greeter.sh /build/warm-greeter-debs
sudo env UV_BIN=/path/to/uv bash scripts/add-board-layer.sh \
  warm-greeter /build/disposable-arm64-root /build/warm-greeter-debs
```

Install the layer before creating a new board image. To restore the distribution greeter and its original configuration on a test image where both packages came from this layer, purge `y700-warm-greeter` and `arctica-greeter` through APT and use the next LightDM start. Arctica's Debian package also installs a global wrapper and local and remote login hints. Its optional remote-login backends are outside this layer. Debian's baseline `lightdm-greeter` alternative prefers its GTK greeter. Local LightDM settings can override the package configuration.

## VM evidence

In a full ARM64 QEMU boot with real systemd and LightDM, the Arctica preferences were enabled in a disposable overlay. A synthetic account was entered through Onboard using absolute USB-tablet taps. The greeter rejected the wrong password, accepted a generated passphrase through the same keyboard and opened a seat0 X11 user session through LightDM. Xfce displayed its window manager, panel and desktop. The Xfce session menu returned to Arctica with the keyboard after graphical logout.

The physical acceptance gate covers initial enrollment, login with the device owner's password, layout on the built-in panel and touch input on the tablet.
