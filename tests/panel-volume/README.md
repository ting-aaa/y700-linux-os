# Xfce panel volume regression

Run as an ordinary user in a disposable Debian 13 guest with the Y700 platform package under test installed. The graphical cases require the packaged tablet Xfce profile, `xfce4-panel`, `xfce4-pulseaudio-plugin`, `xfce4-settings`, `xfwm4`, `xfconf`, `xvfb`, `x11-utils`, `xdotool`, `python3-gi`, `gir1.2-gtk-3.0`, `dbus-daemon`, `pipewire-bin`, `pipewire-pulse`, `wireplumber`, `pulseaudio-utils` and `uv`. Keep audio passthrough disabled so the guest has no `/dev/snd`. Each run starts a new private user profile, session bus and X server. The audio server only receives generated silence.

```sh
bash tests/panel-volume/run.sh desktop
bash tests/panel-volume/run.sh transport
bash tests/panel-volume/run.sh timing-fresh
bash tests/panel-volume/run.sh timing-existing
bash tests/panel-volume/run.sh first-login
bash tests/panel-volume/run.sh first-login-shortcut
bash tests/panel-volume/run.sh first-login-existing
```

- `desktop` reads the packaged autostart entry and verifies that its command places one visible icon immediately after the tray at 200% scaling. It checks repeat startup, an existing icon moved to the second panel, deliberate removal, and an owner-defined volume hotkey. XTEST volume down, up and mute must change the actual PipeWire Pulse sink and the test restores both channel levels and mute state.
- `transport` starts with an existing Xfce window-manager Play shortcut. It verifies that the new applet leaves the transport keys to the existing setup and the applet still handles the simulated volume keys.
- The two timing cases run only real Xfconf, the helper and a controlled D-Bus substitute for the panel. A new plugin must complete despite an unanswered restart request after the old three-second call timeout, and an already configured plugin must complete without requesting a restart. Neither can write its setup marker while the expected wrapper is absent, even when a different wrapper has appeared.
- The three first-login cases source the installed Xsession hook before starting Xfce services. The fresh account must start with a visible volume item and the same panel D-Bus owner before and after Y700 autostart. After removing the item, the fixture re-enters the hook and starts the panel with the same profile. The other two cases preseed either an owner volume shortcut or a custom panel layout and verify that the standard one-time migration preserves them.

The timing cases also accept an executable helper via `Y700_PANEL_QA_HELPER` and only require `xfconf`, D-Bus, Python with Gio and `uv`. The first-login cases require the platform Xsession hook from dev12.4 or later. Successful runs print a `PASS` record for the selected case. These tests exercise X11 userspace with a synthetic keyboard and a virtual output.
