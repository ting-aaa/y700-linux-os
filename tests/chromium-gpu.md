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

## dev12.11 without a desktop session

The dev12.11 image installs Chromium `156.0.8078.47-1~deb13u1`. Its Debian launcher reads `/etc/chromium.d/99-y700-software-rendering`, which adds `--disable-gpu`. The board fixture measures the effective default first. A separate run calls the same installed Chromium ELF directly, requests headless ANGLE Vulkan and keeps Chromium's sandbox and GPU blocklist active. Chromium documents that the Vulkan path can work without X11 on some Linux configurations. Physical Xfce composition and browser video decoding require separate tests. [Upstream headless GPU guidance](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/gpu/using-gpu-hardware-in-headless-chrome.md)

Place `chromium-gpu-board.sh`, `chromium-gpu.py`, and `chromium-gpu.html` together. Set `UV_BIN` to a trusted, executable ARM64 uv. The root supervisor creates private mount, PID and network namespaces, brings up only loopback, and supplies a new home and temporary directory. It runs Chromium as `y700` without display credentials. Each command creates a fresh browser profile and removes it on exit. The hardware run can be made from USB maintenance while the tablet remains at its greeter.

```sh
sudo env UV_BIN=/absolute/path/to/uv bash chromium-gpu-board.sh product
sudo env UV_BIN=/absolute/path/to/uv bash chromium-gpu-board.sh vulkan
```

With the optional `y700-platform 0.1.0~dev12.8+gpu1` installed, the following pair exercises the same Debian launcher in both cases. Each starts with a fresh temporary home. The second run selects the installed GSettings option in that home and requires hardware WebGL, renderer sandboxing and completed GPU work.

```sh
sudo env UV_BIN=/absolute/path/to/uv bash chromium-gpu-board.sh product
sudo env UV_BIN=/absolute/path/to/uv bash chromium-gpu-board.sh product-vulkan
```

The physical dev12.11 tablet passed both controls. SwiftShader rendered 60 frames at the default setting. With the option selected, Chromium reported Turnip Adreno 730, verified four pixels in each of 60 frames and retired work on its own MSM GPU client. These two commands run headless. [Desktop setting and package](../docs/CHROMIUM-GRAPHICS.md)

The product control requires the actual launcher flag, a sandboxed renderer, and a page reporting either software rendering or WebGL 2 unavailable. The Vulkan run additionally requires every sampled frame to match, a renderer string identifying Adreno 730 and Vulkan, and retired work on an MSM DRM client owned by this browser's GPU process. Both commands report renderer seccomp and sandbox-bypass flags. A software renderer, an unattributed GPU, or a timeout leaves the hardware check unverified.

On 21 November 2026, the product control ran inside the ARM64 dev12.11 release in QEMU. Chromium's SwiftShader rendered all 60 frames and the page verified four pixels in each frame. The observer found the packaged disable-GPU flag, seccomp filtering with no-new-privileges in the renderer, and zero attributed MSM work. The local receipt is `out/dev12.11-chromium-gpu/pc-product.log`, SHA-256 `582245d2637108367abfeec4102a3cb94e75fdf25afd08916a04968d065a71f9`.
