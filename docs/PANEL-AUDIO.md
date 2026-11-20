# Xfce volume control and the Y700 volume buttons

Debian on the TB320FC_PRC already exposes both physical volume buttons to the active X11 session. The installed `xfce4-pulseaudio-plugin 0.4.9-1` supplies the panel control and can handle those keys. On November 20 the dev12.1 tablet had no PulseAudio panel instance. Its default output reported `Volume: 0.40`. These observations used read-only queries. Nobody pressed a physical button during this check, so an actual rocker-to-volume change remains untested. [Physical speaker playback](SPEAKERS.md)

## Panel placement

The November 20 upgrade added a single speaker control immediately after the notification area on the physical tablet. X11 reported a mapped 128 × 128 pixel area at (2196, 0) on the 2560 × 1600 internal display at 200% scale. The ten original top-bar items kept their order and the dock retained all eight items. The dev12.3 and dev12.4 package upgrades each recovered a missing setup marker using the existing instance and a private state directory. Both panel layouts and the original wrapper process survived the dev12.4 upgrade. The package verification passed, the output stayed at 40%, and the playback PCM stayed closed. The update required no display wake or audio playback.

In an isolated ARM64 Xfce desktop, the plugin changed a virtual sink's playback volume and mute state. Synthetic X11 volume-down and volume-up events moved 40% to 35% and back. A user-defined command retained its shortcut. Moving the existing plugin to another panel and removing it after setup both persisted across the next helper invocation. Finger input on the physical icon and a mechanical press of each volume key remain to be tested. [Runnable regressions](../tests/panel-volume/README.md)

The Debian `xfce4-panel 4.20.4-1` template starts with two panels. Panel 1 is the top bar with plugin IDs 1–10, including notification area 6 and clock 8. Panel 2 contains IDs 11–18. The template has no PulseAudio entry. On dev12.4 an Xsession hook reads the effective template before the user’s first Xfce login. For a fresh profile it writes a private copy under `$XDG_RUNTIME_DIR/y700-panel-default-*/xfce4/panel/default.xml` and prepends its configuration directory to the session’s `XDG_CONFIG_DIRS`. The stock panel imports that template when its channel has no `/panels` property. The default top bar gains ID 19 after the notification area. [Debian’s upstream template](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/migrate/default.xml.in#L5-L69) · [Xfce template selection](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/migrate/main.c#L63-L96) · [Session hook](../packaging/root/etc/X11/Xsession.d/61y700_panel_default) · [Template generator](../packaging/root/usr/libexec/y700-panel-default)

For an attended change, `xfce4-panel --add-items=1` opens the chooser for panel ID 1. Select **PulseAudio Plugin** and tap **Add**. With multiple panels, `xfce4-panel --add=pulseaudio` opens a panel chooser. With one unlocked panel it adds directly. The D-Bus `AddNewItem` interface accepts a module name and arguments passed to the plugin. `PluginEvent` sends an event to existing instances. [Chooser implementation](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/panel/panel-item-dialog.c#L852-L860) · [Add behavior](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/panel/panel-application.c#L1487-L1526) · [D-Bus methods](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/panel/panel-dbus-service.c#L244-L307)

An unattended update to an existing profile should first check all panels for an existing PulseAudio instance, preserving its position and settings. For a new instance, allocate an ID unused by any panel or plugin subtree, set `/plugins/plugin-ID` to the string `pulseaudio`, then insert the ID into the intended panel's existing integer `plugin-ids` array. Preserve unrelated items and their order. Applying these changes before the panel starts lets it create the wrapper on normal startup. A running panel reads the array again on restart. An array readback alone cannot establish that the wrapper started. After a one-time addition, remember the result per user so later removal is respected. [Provider construction](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/panel/panel-application.c#L447-L471) · [Restart](https://github.com/xfce-mirror/xfce4-panel/blob/xfce4-panel-4.20.4/panel/main.c#L385-L412)

## Physical input and X11

| Button | Live evdev node and capability | Live X11 mapping |
| --- | --- | --- |
| Volume up | `gpio-keys`, event2, `KEY_VOLUMEUP` 115. PM8350 GPIO 6, active low, 15 ms debounce | XInput keyboard 6, keycode 123, `XF86AudioRaiseVolume` |
| Volume down | `pmic_resin`, event1, `KEY_VOLUMEDOWN` 114. PMIC PON RESIN | XInput keyboard 9, keycode 122, `XF86AudioLowerVolume` |

The live device tree reported Linux codes `0x73` and `0x72`. The input devices advertised the corresponding single bits in their EV_KEY capability masks. The separate `pmic_pwrkey` node advertised `KEY_POWER` 116. Kernel event numbers and XInput device IDs above belong to this boot. [Board volume-up declaration](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0006-asphalt-board-dts.patch#L80-L96) · [PON RESIN declaration](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0006-asphalt-board-dts.patch#L604-L612)

## Shortcut ownership

The Debian ARM64 module links to `libkeybinder-3.0`. At X11 startup it reads the instance's `enable-keyboard-shortcuts` preference, which defaults to true. It attempts four independent grabs for the group. An existing exclusive grab can cause a warning and partial success. Raise and lower change the output volume in five-percentage-point steps by default. A separate `enable-multimedia-keys` preference controls playback keys and defaults to true in an MPRIS build. [Defaults](https://github.com/xfce-mirror/xfce4-pulseaudio-plugin/blob/xfce4-pulseaudio-plugin-0.4.9/panel-plugin/pulseaudio-config.c#L45-L59) · [X11 startup](https://github.com/xfce-mirror/xfce4-pulseaudio-plugin/blob/xfce4-pulseaudio-plugin-0.4.9/panel-plugin/pulseaudio-plugin.c#L562-L573)

| Instance preference | Unmodified key names |
| --- | --- |
| `enable-keyboard-shortcuts` | `XF86AudioLowerVolume`, `XF86AudioRaiseVolume`, `XF86AudioMute`, `XF86AudioMicMute` |
| `enable-multimedia-keys` | `XF86AudioPlay`, `XF86AudioStop`, `XF86AudioPrev`, `XF86AudioNext` |

Keep existing plugin preferences and bindings for both Xfce shortcut providers. In the `xfce4-keyboard-shortcuts` channel, `commands` serves xfsettingsd and `xfwm4` serves the window manager. On this tablet both providers' `custom/override` flags were true. Neither custom tree contained any of the eight keys. Xfce initializes the custom tree from the corresponding default tree if the override is inactive. When provisioning a new plugin, preserve an occupied shortcut by disabling its corresponding group on that instance before startup. The menu and slider work independently of global key grabs. Other X11 clients can also reserve a key, so an empty Xfconf entry alone cannot prove exclusive ownership. [Active shortcut tables](https://github.com/xfce-mirror/libxfce4ui/blob/libxfce4ui-4.20.1/libxfce4kbd-private/xfce-shortcuts-provider.c#L165-L177) · [Command provider](https://github.com/xfce-mirror/xfce4-settings/blob/xfce4-settings-4.20.1/xfsettingsd/keyboard-shortcuts.c#L108-L117) · [Window-manager provider](https://github.com/xfce-mirror/xfwm4/blob/xfwm4-4.20.0/src/settings.c#L1098-L1104) · [Volume and media key handlers](https://github.com/xfce-mirror/xfce4-pulseaudio-plugin/blob/xfce4-pulseaudio-plugin-0.4.9/panel-plugin/pulseaudio-plugin.c#L335-L449)

To check the current mapping, plugin and output without changing them, run these commands in the signed-in Xfce session. The shipped desktop provides `wpctl`. A configured instance may omit the shortcut preference when it uses the default. The wrapper process and its module path distinguish a loaded instance from a saved panel entry.

```sh
xinput list --short | grep -E 'gpio-keys|pmic_resin|pmic_pwrkey'
xmodmap -pke | grep -E '^keycode +(122|123) '
xfconf-query -c xfce4-panel -lv | grep -E 'pulseaudio|enable-(keyboard-shortcuts|multimedia-keys)'
xfconf-query -c xfce4-keyboard-shortcuts -l | grep -E '/(commands|xfwm4)/(custom|default)/XF86Audio'
pgrep -a -u "$(id -u)" -f '[w]rapper.*libpulseaudio-plugin[.]so'
wpctl get-volume @DEFAULT_AUDIO_SINK@
```
