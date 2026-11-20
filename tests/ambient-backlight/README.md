# Ambient light policy fixture

Run `sh tests/ambient-backlight/check.sh` on a Linux host as an ordinary user with uv, Debian's system Python and PyGObject, GLib 2.84 or later, dconf and dbus-daemon. An optional first argument selects the root directory of an extracted platform package. The runner launches private system and session buses, compiles the product schema, and creates a temporary dconf profile, backlight and DRM connector. It shortens the sampling and settling intervals in the test process. [SensorProxy light interface](https://hadess.pages.freedesktop.org/iio-sensor-proxy/gdbus-net.hadess.SensorProxy.html)

The checks cover all eight CN350 curve points, interpolation, steady light, short excursions, noisy convergence, manual adjustments and the logind target. The private services also exercise lock, logout, seat ownership, DPMS and backlight power, missing sensors, invalid readings, proxy replacement, a lost claim, cancellation and shutdown. The runner checks the absence of sensor, locker and login service activation.

## Connecting the installed GUI and daemon

Reuse the private bus pair, schema, dconf profile and `XDG_SESSION_ID=c42` environment from `check.sh`. Run the following under the test user's UID with a new directory owned by that user. The fixture imports `tests/rotation-session.py` for its mock services.

```sh
uv run --offline --no-project --python /usr/bin/python3 python -B \
  tests/ambient-backlight/check.py /usr/libexec/y700-ambient-backlight "$work" --serve
```

The server creates `$work/ready` when all three providers and the control interface are available. Its sysfs tree contains `$work/sys/class/backlight/ktz8866-backlight` and `$work/sys/class/drm/card2-DSI-1`. A disposable private mount namespace can bind the parent directories over the matching class paths before starting the installed GUI and daemon through their ordinary launchers.

Send controls on the private system bus using service and interface `org.y700.AmbientFixture` and object `/org/y700/AmbientFixture`. The initial light level is 10 lux and the backlight begins at 400 of 2047.

| Method | Effect |
| --- | --- |
| `Lux(double)` | Publish a new light reading to the claiming sender. A settled 10 or 350 lux yields raw 161 or 1228. |
| `Locked(boolean)` | Change the Xfce screensaver lock state. |
| `Panel(boolean)` | Change DSI-1 DPMS between On and Off. |
| `State() → (uint32, uint32)` | Read the current count of claiming senders and the cumulative number of logind writes. |

The mock logind accepts the named test session and the GUI's `/session/auto` alias. Stop the fixture with SIGTERM after the GUI and daemon exit.
