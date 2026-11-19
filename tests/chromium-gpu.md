# Chromium WebGL on Adreno 730

The probe draws alternating colors with a WebGL 2 shader and reads four RGBA samples per frame. It reports the readback, Chromium version when exposed, and unmasked WebGL renderer and driver strings as JSON. Exit status zero requires every requested frame to match, evidence of Adreno 730 (`FD730` or `Adreno (TM) 730`), and a Mesa, Freedreno or Turnip marker. Software renderer signatures cause rejection even if pixels match.

For an attended run on the GPU candidate, use the signed-in, unprivileged X11 session and its existing X authorization. Keep the HTML next to the runner. Start with the default backend and capture a receipt. The runner starts a single disposable profile, serves the page over an ephemeral loopback address and closes the test browser afterward. On Debian it directly launches `/usr/lib/chromium/chromium` so this invocation can exercise the GPU while the product's regular desktop launcher continues to apply `--disable-gpu`.

```sh
uv run --no-project --python 3.13 python tests/chromium-gpu.py \
  --frames 120 --timeout 60 > chromium-gpu-receipt.json
```

For a separately approved backend-specific run, add `--backend gles` or `--backend vulkan`. The runner requests that ANGLE backend and checks that the raw renderer string identifies the corresponding API. A Release Chromium build can expose a generic ANGLE label, omit `WEBGL_debug_renderer_info`, or report the GPU model without naming its driver. Those cases exit nonzero and preserve the raw strings for comparison. Keep the browser's sandbox and GPU blocklist in effect.

The receipt covers shader draw and pixel readback in this browser session. Record the matching kernel boot, DRM submissions and kernel fault log independently before interpreting a physical trial. Browser compositing, video decode, suspend, and long-run stability have separate acceptance criteria.

Run the synthetic classifier decision tests on any PC with `uv`. For a browser-level negative control, use an existing Chrome or Chromium executable and add `--headless --software-control`. That command should exit nonzero with a software renderer or an unavailable WebGL context.

```sh
uv run --no-project --python 3.13 python tests/chromium-gpu.py --self-test
```
