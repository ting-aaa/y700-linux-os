# Windowed Chromium on the Y700 panel

`run.sh` opens a 640 × 480 test window while dev12.11 is at the LightDM greeter. The installed Debian Chromium launcher reads the `org.y700.chromium hardware-acceleration` setting from a fresh temporary account. The host X server receives an input-transparent window containing a private Xephyr display. A new login or a second graphical session aborts the test.

Run from this directory as root, with the ARM64 `uv` executable and the distribution's Xephyr available. The default Xephyr location is `/run/y700-x11-deps/usr/bin/Xephyr`, with its private library search path at `/run/y700-x11-deps/usr/lib/aarch64-linux-gnu`. Set `XEPHYR_BIN` and `XEPHYR_LIB` to override those locations. The installed `y700-platform` package must provide the Chromium GSettings policy.

```sh
UV_BIN=/path/to/uv Y700_WINDOW_POLICY=software bash run.sh
UV_BIN=/path/to/uv Y700_WINDOW_POLICY=hardware bash run.sh
UV_BIN=/path/to/uv Y700_WINDOW_POLICY=hardware Y700_WINDOW_FRAMES=1800 bash run.sh
```

The default is 60 frames. An even frame count from 60 through 1,800 preserves the expected final quadrant colors. Each WebGL 2 frame changes the shader output and checks four RGBA values. In the software profile, a browser that rejects the WebGL 2 context reports the original error and zero WebGL frames. A separate Canvas 2D control then paints and verifies the same colors.

The hardware run requires a Vulkan Adreno 730 renderer, the launcher's ANGLE flags, a sandboxed renderer and positive MSM engine counters on a file descriptor in the browser's GPU process. Both profiles require the browser window to be mapped on the nested X server. On the host, the observer reads four individual pixels three times from the named pixmap for Xephyr's child window. It verifies unobscured visibility, an empty input shape, sole active DSI output, DPMS on and a lit backlight. These checks cover presentation through Xephyr. Direct Vulkan swapchain presentation and optical panel output require separate measurements.

The browser has only loopback networking, a private home and an isolated nested display cookie. The host cookie and socket used by Xephyr occupy a private mount namespace. Temporary credentials and browser state disappear on exit. An initially sleeping greeter is restored to its prior DPMS state if the same greeter remains active and no intervening input was detected.

On an ARM64 QEMU `virt` guest, `VM_XAUTHORITY=/path/to/private/Xvfb.auth Y700_WINDOW_POLICY=software bash run.sh --vm-control` can exercise the software path against an authenticated Xvfb on `:0`. Panel and MSM checks apply to the physical mode.
