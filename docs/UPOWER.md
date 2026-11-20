# Debian UPower on the Y700 battery interface

The generic dev12.6 root contains 1,115 packages. Its original inventory has libgudev and polkit, and adding six Debian runtime archives is sufficient to run UPower 1.90.9. The dependency set is `upower`, `libupower-glib3`, `libimobiledevice-1.0-6`, `libimobiledevice-glue-1.0-0`, `libplist-2.0-4` and `libusbmuxd-2.0-7`. They total 352,264 bytes on arm64. Installing them on a disposable copy passed `dpkg --audit` and `apt-get check`. The product's separate desktop layer adds the Xfce manager, its data package and tablet defaults. [Original root](ROTATION-IMAGE.md) · [Debian runtime source](https://packages.debian.org/trixie/source/upower) · [Desktop layer package and archive hashes](../config/power-desktop.lock.json)

## What the 48 W reading means for the desktop

The board kernel reports `charge_full`, `charge_full_design`, `charge_counter`, percentage, voltage and current. Four USB-attached readings showed a full battery, 100%, around 4.417 V and zero battery current alongside roughly 48 W from the independent firmware `power_now` property. The discrepancy in that firmware property remains unresolved. [Physical readings and ABI](BOARD-HEALTH.md)

For this charge-based ABI, Debian UPower reads `current_now` and converts it to an energy rate. When energy and `charge_now` are unavailable, it estimates remaining energy using full capacity and percentage. With no design-voltage attributes it uses the present voltage for the conversion. At 5.078 Ah and 4.417 V the reported full energy is about 22.43 Wh. That figure and the time estimates depend on these inputs. [Linux battery backend](https://sources.debian.org/src/upower/1.90.9-1/src/linux/up-device-supply-battery.c/) · [UPower battery calculations](https://sources.debian.org/src/upower/1.90.9-1/src/up-device-battery.c/)

The private ARM64 fixture runs the real Debian `upowerd` and queries its system-bus API. It provides a synthetic battery, PMIC USB, offline wireless supply and two UCSI connectors, with one connector tracking USB. The full case reproduces the recorded magnitudes with rounded inputs. The other cases exercise declared states on synthetic hardware using the same daemon and a debug refresh. All three keep `power_now` fixed at 48 W.

| Synthetic inputs | UPower `DisplayDevice` | Energy rate | Time to empty / full |
| --- | --- | ---: | --- |
| Full, 100%, 0 A, USB online | Fully charged | 0 W | 0 / 0 s |
| Discharging, 50%, −1 A, USB offline | Discharging | 4.417 W | 9,140 / 0 s |
| Charging, 60%, +1 A, USB online | Charging | 4.417 W | 0 / 7,312 s |

The experiment also read the individual battery and USB objects. The full battery object agreed with the aggregate on state, percentage and energy rate. UPower classified PMIC USB as online line power and exposed the two UCSI providers separately. Unplug/replug behavior and runtime estimates on the physical tablet require a physical discharge/charge observation.

## Reproducing the isolated check

The Linux host needs root for private mount, PID, IPC and network namespaces, native arm64 execution or ARM64 binfmt, and ordinary Debian image build tools. The sealed root is a read-only loop mount. All dpkg writes go to a disposable upper directory. The bus has no service activation directories or logind. `/sys` is a separate tmpfs; the fixture enables systemd's synthetic-sysfs test switch and changes only files in that tmpfs. No host power service or device is part of the test.

The first command below uses `gpgv` and the local authenticated Trixie metadata from 12 September 2026. It checks the signed index digest and all six archives, then writes the runtime directory, `SHA256SUMS` and `archives.tsv`. The last argument is a new directory. [Source index and signing metadata](../config/power-desktop-debian-auth.lock.json) · [Fixture](../tests/upower/run.sh)

```bash
bash tests/upower/fetch.sh "$inrelease" "$arm64_packages" "$debian_archive_keyring" "$new_archives"
sudo bash tests/upower/run.sh "$sealed_dev12_6_root" "$new_archives"
```

## Xfce notification-area check

Xfce Power Manager 4.20 can place a GtkStatusIcon in the existing Xfce notification area. The optional power-manager panel plugin adds a separate panel component. The older standalone `xfce4-battery-plugin` 1.1.5 reads Linux sysfs directly. Its adapter detection looks for `Mains`, and it assigns the same rate field while traversing `current_now` and `power_now`. Its calculations depend on the encountered fields and their units. [Xfce 4.20 manager source](https://sources.debian.org/src/xfce4-power-manager/4.20.0-1/src/xfpm-manager.c/) · [Xfce battery-plugin backend](https://sources.debian.org/src/xfce4-battery-plugin/1.1.5-1/panel-plugin/libacpi.c/)

In the isolated ARM64 desktop, the ordinary `y700` account loaded the product's Xfconf defaults in a fresh session. The real Debian `xfce4-panel` embedded the stock manager's 22×22 icon at (0, 9) on a 1024×768 Xvfb screen. A primary pointer click left the menu closed. A secondary click opened the manager's 176×109 GTK menu at (15, 20). Pressing End and Return in that menu launched the separate Power Manager Settings process and displayed its window. Setting `show-tray-icon=false` removed the icon across a manager restart; restoring the preference redocked it. The test uses X11 pointer and key events. Physical touch needs its own observation. [Tray actor](../tests/upower/tray.sh)

Use the product layer's archive directory and an ARM64 test tree containing `bin/Xvfb`, `bin/xdotool` and `lib/aarch64-linux-gnu/libxdo.so.3` to run this check. The tester copies these three files into its disposable root. The panel configuration contains only the stock systray plugin so the status icon has an unambiguous parent. The X server has a temporary cookie and accepts local connections inside the namespace.

```bash
sudo env UV_BIN="$(command -v uv)" bash tests/upower/run.sh \
  "$sealed_dev12_6_root" "$new_archives" "$desktop_archives" "$arm64_x11_usr"
```

With `xfce4-power-manager 4.20.0-1+y7001`, the test ran at 2560×1600 and 200% GTK scaling. A primary click, a secondary click and Return sent directly to the focused tray icon each opened a 352×218 menu owned by the manager. Each menu opened a new, visible Power Manager Settings process. The opt-out persisted across a manager restart. Run with `Y700_TRAY_SCREEN=2560x1600 GDK_SCALE=2 Y700_TRAY_CHECK_RETURN=1` in the `sudo env` invocation to exercise the same inputs. The focus check explicitly puts focus on the icon before sending Return; tab navigation through the entire panel is a separate path.

| Local receipt in `out/upower/` | SHA-256 |
| --- | --- |
| `arm64-runtime-sealed.log`, three synthetic battery states | `46166f21d80265b5a4dd5c954d2eb6863b5132bb46a722453b3e3a3bca8811b6` |
| `arm64-tray-settings.log`, Debian 4.20.0-1 at 1× | `6bde9de0b2f9da83e92b7b777cece9ddb8e5a1a809b0ec8c2e0420e0d309ceb7` |
| `arm64-tray-candidate-final.log`, 4.20.0-1+y7001 at 2× | `66f6786d45d8705e5ccba5275846149523aa737dbd77061d2fdfa8fd0b855051` |
