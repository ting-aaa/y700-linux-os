# Tablet brightness

Open **Settings → Hardware → Tablet brightness** in Xfce, or **设置 → 硬件 → 平板屏幕亮度** in Simplified Chinese. Use **−** and **+** to adjust the internal display in small steps, or choose one of the percentage buttons. The percentage shows the requested backlight level as a share of the driver's range. **Restore opening level** reapplies the exact nonzero setting read when the window opened. The 5% preset and ordinary dimming floor use the same raw level as the Y700 driver's initial setting, 102 on its 0–2047 range.

The Xfce Hardware settings category includes all three tablet display tools. The top bar also includes Xfce Power Manager on the current board image. [Power manager and battery menu](POWER-MANAGER-TOUCH.md)

### Touch slider on the installed dev12.11 tablet

Drag **Screen brightness** (`屏幕亮度`) to choose any whole percentage from 5 to 100. The value follows the finger and is applied on release. A canceled touch returns to the current setting. The keyboard arrow keys move one percentage point at a time. The slider occupies 56 logical pixels vertically, or 112 display pixels at 200%. The small-step, preset and restore controls remain available. The settings app sends manual changes through the active session's logind service. [GTK touch event handling](https://docs.gtk.org/gtk3/input-handling.html)

The installed platform package is `0.1.0~dev12.8+gpu1.2`. Against private light and backlight inputs on the tablet's CPU, both English and Chinese windows reached 79% by mouse drag, reached 7% with Home and two arrow-key presses, then restored the exact opening value of 400/2047. In a full ARM64 guest, the normal GTK window at 200% received Linux Type-B touchscreen contacts through Xorg and libinput. A tap and drag to the same position each selected 80% (1637/2047), a reverse drag selected 5% (102/2047), and tapping restore returned to 400/2047. [Touchscreen test](../tests/brightness/slider-touch-test.md)

In the guest, both slider versions reached the same endpoints when the simulated backlight published each sysfs reading atomically. With five contact sequences, the first slider sent intermediate brightness requests during a drag. The installed revision sent one request on each release, five in total. The initial fixture could briefly expose an empty file while updating its value and produced a misleading short drag on the older version.

The original dev12.11 archive can first receive the Chromium platform update. The slider helper accepts that version or the first slider package as the previous package. The `.1` → `.2` pair, helper and checksums are in `out/dev12.11-brightness-touch/`. [Chromium update](CHROMIUM-GRAPHICS.md)

```sh
sudo bash update-brightness-slider.sh install \
  y700-platform_0.1.0~dev12.8+gpu1.1_all.deb y700-platform_0.1.0~dev12.8+gpu1.2_all.deb
```

Use `rollback` with the same pair to reinstall the previous package. The two independent `.2` builds produced SHA-256 `479c59b518f42e035f9101feb5947ba972df32b1a5646f62b459bc13b5357518`. The installed tablet passed its 1,240-package manifest, program hash and desktop service checks after the upgrade. [Build recipe](../scripts/build-brightness-slider.sh)

## Automatic brightness

After a normal Xfce login, open **Tablet brightness** and select **Automatic brightness** (简体中文 **自动亮度**). The setting defaults to off. The desktop follows ambient light while the internal panel is lit and the local session is unlocked. Choosing a different manual level turns the option off. If the sensor service is unavailable, the window displays a waiting message and keeps the current level. On the installed dev12.11 tablet the SLPI and `y700-ssc.service` were running after both panel trials. [Post-suspend sensor readings](DEV12.11-VERIFICATION.md)

The Linux policy interpolates eight control points from the CN350 Android framework resources. The resource arrays map ambient light to target nits, then target nits to a backlight request on a 0–255 scale. The worker converts that request to the Linux driver's range, waits four seconds for a stable target and filters changes within four Android backlight units. These are requested brightness levels. Optical luminance and the response to changing light on the physical panel still need measurement. [AOSP display configuration](https://android.googlesource.com/platform/frameworks/base/+/5b361c07f928fd8c02a347b074a50b977e044f97/services/core/java/com/android/server/display/DisplayDeviceConfig.java) · [AOSP brightness resource definitions](https://android.googlesource.com/platform/frameworks/base/+/7951f5d173cbf3904399ebd042c771a88e894c61/core/res/res/values/config.xml)

| Ambient light (lux) | 0 | 10 | 60 | 210 | 350 | 420 | 1000 | 1001 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Android backlight request | 20 | 20 | 51 | 77 | 153 | 214 | 250 | 255 |

To verify the curve against your own copy of CN350 `/system/framework/framework-res.apk`, run `uv run --no-project --python 3.13 python tests/brightness/check-stock-curve.py "$aapt2" "$apk"`. The verifier checks the exact APK digest, reads the four default arrays with Android AAPT2 and compares their composition with the packaged worker. [Verifier](../tests/brightness/check-stock-curve.py)

On the physical tablet with dev12.8 installed, the GUI and worker ran on a private 2560 × 1600 display at 200% scaling. The test used synthetic light, backlight, lock and display-power states. Pointer taps in the English and Chinese windows exercised the same commands as the installed desktop entries. At 10 lux the worker requested 161/2047. At 350 lux it requested 1228/2047 and the UI displayed 60%. Locking and blanking released the sensor. Tapping the manual 25% preset requested 511/2047 and stopped subsequent automatic writes. The saved choice survived reopening and the Chinese window indicated sensor loss. The owner session, real backlight, sensor DSP and services retained their initial state. A prior bounded test measured **17.7435 lux from the real sensor**. [Tablet GUI fixture](../tests/brightness/run-ambient-tablet.sh) · [Physical sensor reading](SSC-TRIAL.md#read-from-the-ordinary-desktop-account)

## Driver and session authorization

The native Linux board device tree selects the I²C KTZ8866 driver. The driver registers `/sys/class/backlight/ktz8866-backlight` with maximum brightness 2047. The GTK process reads the requested level from sysfs. Its only write request is `org.freedesktop.login1.Session.SetBrightness("backlight", "ktz8866-backlight", level)` on its own login1 session. In the measured logind version, the service verifies the foreground session, the caller's effective UID and the device seat before writing. [Pinned board driver](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0002-asphalt-display.patch) · [systemd 257.13 session method](https://github.com/systemd/systemd/blob/v257.13/src/login/logind-session-dbus.c#L665-L713) · [Linux backlight API](https://docs.kernel.org/gpu/backlight.html)

Writing `brightness` stores the requested level and invokes the driver. When `bl_power=4`, the backlight core passes effective level zero to the KTZ8866 update. Its zero branch clears LED enable and the brightness registers. The driver's lack of a `get_brightness` operation means sysfs `actual_brightness` reports the stored setting. [Kernel health snapshot](BOARD-HEALTH.md)

## TB320FC_PRC verification

On the tablet's ARM64 CPU, an authenticated private Xvfb display ran the packaged tablet Xfce profile at scale factor 2. Real Xfce Settings Manager displayed brightness, scale and rotation under Hardware in both English and Simplified Chinese. With `y700-platform 0.1.0~dev11.1` installed, all three desktop IDs resolved directly to `/usr/share/applications` and their packaged `/usr/libexec` commands. Their theme icons loaded and `dpkg -V` was clean. A single synthesized pointer tap on the brightness item opened the installed GTK window in each language. AT-SPI reported eight controls with targets of at least 50 × 56 logical pixels. The brightness and backlight power state stayed at their original values during the installed menu verification.

In a separate guarded trial using the same GTK executable, the ordinary signed-in X11 user's process resolved to the active, local LightDM seat. With the backlight already powered down, one synthesized pointer tap on **+** requested 102 → 122 of 2047 through real logind. A second tap on **Restore opening level** returned it to 102. `bl_power` remained 4 throughout. An independent 75-second restore timer was armed before the first tap and removed after the expected value returned. The boot, active session, LightDM and USB SSH service invocations were preserved.

On the installed dev12.11 tablet, a separate measurement lit the internal DSI panel at the greeter. Its ordinary foreground UID requested 102 → 122 → 102 through logind. Each time, two reads of the KTZ8866's brightness and LED-enable registers agreed with the requested level. After blanking, the chip reported zero with the LEDs disabled while Linux retained the requested 102 for the next wake. The measurements establish the programmed current level. Optical luminance and a finger drag on the physical glass require separate observations. [On-device steps and register readback](../tests/brightness/lit-board-step.sh) · [KTZ8866 datasheet](https://www.kinet-ic.com/uploads/web/KTZ8866/KTZ8866-04b.pdf)

## Private UI probe

Place `tests/brightness/session.sh`, `tests/brightness/probe.py`, the app and its desktop entry in a disposable bundle with ARM64 `uv`, `Xvfb` and `xdotool` under `bin/`. Use the ordinary user's process and leave the product's Xfce profile available at `/usr/share/y700/tablet-xdg`.

```sh
bash "$bundle/session.sh" en
bash "$bundle/session.sh" zh
```

These two calls check the layout without moving the hardware level. The write-path probe takes an explicit original level, candidate level and active session ID. Its harness verifies an already powered-down panel and arms an independent, conditional restore before invoking that phase.
