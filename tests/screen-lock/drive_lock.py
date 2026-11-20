"""Exercise the native panel action and embedded keyboard with Type-B taps."""
import time

from drive import SCREEN_WIDTH, enter, panel, wait_marker


# Centers of the rendered Compact keys in the 1024x768 lock-dialog fixture.
LOCK_KEYS = {
    "a": (150, 666), "b": (435, 704), "c": (313, 704), "d": (273, 666),
    "e": (259, 627), "f": (337, 666), "s": (212, 666), "y": (444, 627),
}


def control(work, marker, timeout=70, detect_calendar=False):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for line in (work / "report.log").read_text(errors="replace").splitlines():
            if line.startswith(marker + " "):
                x, y = map(int, line.split()[1:])
                if not 0 <= x < SCREEN_WIDTH or not 0 <= y < 768:
                    raise ValueError("Xfce lock action outside the screen")
                return x, y
            if line.startswith("COMBINED_FAIL "):
                raise RuntimeError("Guest lock observer failed")
        if detect_calendar and "SCREEN_LOCK_CALENDAR_OPEN" in (work / "report.log").read_text().splitlines():
            return None
        time.sleep(.3)
    raise TimeoutError(marker)


def cancel_text(frame, y):
    pattern = []
    for row in range(y - 6, y + 7):
        for x in range(491, 533):
            offset = (row * SCREEN_WIDTH + x) * 4
            pattern.append(sum(frame[offset:offset + 3]) < 410)
    return pattern


def unlock_form(work):
    # Sample the q key's fill, outline and printed glyph, and the Unlock button
    # on the pinned 1024x768 XFCE desktop. Discard each synthetic frame.
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        frame = panel(work)

        def brightness(x, y):
            index = (y * SCREEN_WIDTH + x) * 4
            return sum(frame[index:index + 3])

        if (brightness(115, 615) > 500 and brightness(107, 609) < 80
                and brightness(134, 633) < 80 and brightness(650, 427) > 600
                and brightness(614, 424) < 400):
            pattern = cancel_text(frame, 424)
            if sum(pattern) > 20:
                return pattern
        time.sleep(.5)
    raise TimeoutError("The embedded compact keyboard and Unlock button did not render")


def cancel_button(work, pattern):
    # PAM's failure message may shift the buttons vertically. Match only the
    # Cancel word against the same form's initially enabled button.
    until = time.monotonic() + 35
    last_y = None
    while time.monotonic() < until:
        frame = panel(work)
        matches = [y for y in range(365, 490)
                   if sum(a != b for a, b in zip(cancel_text(frame, y), pattern)) <= 5]
        if len(matches) == 1 and last_y == matches[0]:
            return 512, last_y
        last_y = matches[0] if len(matches) == 1 else None
        time.sleep(.5)
    raise TimeoutError("The enabled Cancel button did not render after the PAM failure")


def unlock(work, touch, secret):
    wait_marker(work, "SCREEN_LOCK_DRAFT_READY", 350)
    button = control(work, "SCREEN_LOCK_PANEL_BUTTON")
    enter(touch, {}, "", button)
    row = control(work, "SCREEN_LOCK_PANEL_ROW", detect_calendar=True)
    if row is None:
        # Dismiss the observed clock popup by touching the draft. Then use the
        # account control, whose bounds came from the actual running panel.
        enter(touch, {}, "", control(work, "SCREEN_LOCK_DRAFT_POINT"))
        enter(touch, {}, "", button)
        row = control(work, "SCREEN_LOCK_PANEL_ROW")
    enter(touch, {}, "", row)
    wait_marker(work, "SCREEN_LOCK_ACTIVE", 120)
    enter(touch, {}, "", (500, 360))
    wait_marker(work, "SCREEN_LOCK_DIALOG keyboard=embedded", 120)
    cancel_pattern = unlock_form(work)
    enter(touch, {}, "", (543, 386))
    wrong = ("a" if secret[0] != "a" else "s") + secret[1:]
    enter(touch, LOCK_KEYS, wrong, (625, 425))
    wait_marker(work, "SCREEN_LOCK_BAD_PASSWORD_REJECTED", 90)
    enter(touch, {}, "", cancel_button(work, cancel_pattern))
    wait_marker(work, "SCREEN_LOCK_CANCEL_STILL_LOCKED", 80)
    enter(touch, {}, "", (500, 360))
    wait_marker(work, "SCREEN_LOCK_PROMPT_READY_FOR_RETRY", 90)
    unlock_form(work)
    enter(touch, {}, "", (543, 386))
    enter(touch, LOCK_KEYS, secret, (625, 425))
    wait_marker(work, "SCREEN_LOCK_SAME_SESSION_DRAFT_RESTORED", 100)
