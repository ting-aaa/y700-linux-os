"""Drive real Onboard and IBus controls, observing focus and commits in Chromium's DOM."""

import json
import sys

import probe as core


def dom():
    return json.loads((core.ROOT / "browser.json").read_text(encoding="utf-8"))


def focus_element(element):
    data = dom()
    ox, oy, width, height = core.wait_for(
        lambda: next(core.windows("--name", "^Y700 input fixture( - Chromium)?$"), None),
        "chromium-fixture-window-not-visible",
    )
    scale = data["scale"]
    viewport_x, viewport_y = data["viewport"]
    x_offset, y_offset = width - round(scale * viewport_x), height - round(scale * viewport_y)
    if not 0 <= x_offset <= 4 or not 0 <= y_offset <= 150:
        raise core.ProbeError("chromium-renderer-viewport-and-x11-client-disagree")
    x, y, component_width, component_height = data[element]
    core.tap(ox + round((x + component_width / 2) * scale),
             oy + y_offset + round((y + component_height / 2) * scale))
    core.wait_for(lambda: dom()["active"] == element, "chromium-dom-focus-" + element)


def editor_with_keyboard(phase):
    if dom()["active"] != "ready":
        focus_element("ready")
    focus_element("entry")
    onboard = "automatic"
    try:
        core.wait_for(core.keyboard_geometry, "onboard-not-auto-shown-by-chromium", 8)
    except core.ProbeError:
        icon = next((box for box in core.windows("--class", "^Onboard$") if
                     16 <= box[2] <= 160 and 0 <= box[1] < 160), None)
        if not icon:
            icon = next((box for box in core.windows("--name", "^Onboard$") if
                         16 <= box[2] <= 160 and 0 <= box[1] < 160), None)
        if not icon:
            raise core.ProbeError("stock-onboard-tray-icon-not-found")
        core.tap_center(icon)
        core.wait_for(core.keyboard_geometry, "onboard-tray-did-not-show-keyboard")
        focus_element("entry")
        onboard = "tray"
    print(f"CHINESE_INPUT_CHROMIUM_FOCUS phase={phase} browser_active_element=entry scale=2 onboard={onboard}",
          flush=True)
    return onboard


def main():
    core.Atspi.init()
    core.Atspi.set_timeout(2200, 2200)
    core.IBus.init()
    initial = core.wait_for(dom, "chromium-page-state-missing")
    if initial["scale"] != 2 or initial["committed"] or initial["active"] != "ready":
        raise core.ProbeError("chromium-empty-page-with-initial-button-focus-required")
    gtk_scale = core.Gdk.Display.get_default().get_monitor(0).get_scale_factor()
    if gtk_scale != 2:
        raise core.ProbeError("chromium-fixture-gtk-scale-not-200-percent")
    editor_with_keyboard("launch")
    bus = core.IBus.Bus.new()
    core.wait_for(lambda: core.current_engine(bus) == "xkb:us::eng", "chromium-english-engine-not-active")
    core.switch_engine(bus, "libpinyin", lambda name: "Intelligent Pinyin" in name, gtk_scale)
    onboard = editor_with_keyboard("pinyin")
    core.type_onboard("nihao")
    candidate = core.wait_for(lambda: core.visible_named(lambda name: name.strip() == "你好",
                                                        (core.Atspi.Role.LABEL,)),
                              "chromium-libpinyin-candidate-missing")
    original = dom()
    if original["committed"] or not original["preedit"]:
        raise core.ProbeError("chromium-pinyin-was-not-preedit-before-tap")
    for attempt in (1, 2):
        number = core.candidate_number(candidate)
        if not number:
            raise core.ProbeError("chromium-candidate-number-not-visible")
        box = core.rect(number)
        x = (box.x + box.width // 2) * gtk_scale
        y = (box.y + box.height // 2) * gtk_scale
        core.command("xdotool", "mousemove", str(x), str(y))
        chain = core.pointer_input_windows()
        if not chain or '"ibus-ui-gtk3"' not in chain[0][1]:
            raise core.ProbeError("chromium-candidate-pointer-target-not-ibus")
        core.tap(x, y)
        try:
            core.wait_for(lambda: dom()["committed"] == "你好" and not dom()["preedit"],
                          "chromium-popup-tap-did-not-commit", 4)
        except core.ProbeError:
            if attempt == 2 or dom()["committed"] or dom()["preedit"] != original["preedit"]:
                raise
        else:
            break
    print(f"CHINESE_INPUT_CHROMIUM pinyin_osk_letters=5 dom=你好 candidate_taps={attempt} onboard={onboard}",
          flush=True)
    core.switch_engine(bus, "xkb:us::eng", lambda name: "English" in name and "US" in name, gtk_scale)
    editor_with_keyboard("english")
    core.type_onboard(" hello")
    core.wait_for(lambda: dom()["committed"] == "你好 hello" and not dom()["preedit"],
                  "chromium-english-after-switch-missing")
    print("CHINESE_INPUT_CHROMIUM_LATIN tray_switch=1 dom=你好_hello", flush=True)
    print("CHINESE_INPUT_UI_PASS", flush=True)


if __name__ == "__main__":
    try:
        main()
    except core.ProbeError as error:
        print(f"CHINESE_INPUT_ERROR {error}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        print(f"CHINESE_INPUT_ERROR {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)
