"""Two keyboard profiles and a bounded typing exercise for the virtual accessory."""
import os
import re


TEXT_MODE = os.environ.get("Y700_BT_TYPING") == "1"
F15 = 0x6a

# Eight modifier bits, reserved byte, six simultaneous keyboard usages.
TEXT_DESCRIPTOR = bytes.fromhex(
    "05 01 09 06 a1 01 85 01 05 07 19 e0 29 e7 15 00 25 01 75 01 95 08 81 02 "
    "75 08 95 01 81 01 19 00 29 73 15 00 25 73 95 06 75 08 81 00 c0"
)
F15_DESCRIPTOR = bytes.fromhex(
    "05 01 09 06 a1 01 85 01 05 07 09 6a 15 00 25 01 75 01 95 01 81 02 "
    "75 07 95 01 81 03 c0"
)
MOUSE_DESCRIPTOR = bytes.fromhex(
    "05 01 09 02 a1 01 85 02 09 01 a1 00 05 09 19 01 29 03 15 00 25 01 "
    "95 03 75 01 81 02 95 01 75 05 81 03 05 01 09 30 09 31 09 38 15 81 "
    "25 7f 75 08 95 03 81 06 c0 c0"
)
REPORT_MAP = (TEXT_DESCRIPTOR if TEXT_MODE else F15_DESCRIPTOR) + MOUSE_DESCRIPTOR
CLEAR = bytes(8 if TEXT_MODE else 1)


def report(usage, modifiers=0):
    if not TEXT_MODE:
        assert usage == F15 and not modifiers
        return b"\x01"
    return bytes((modifiers, 0, usage, 0, 0, 0, 0, 0))


def typing_reports(nonce):
    """Only accept a random fixture nonce, never arbitrary keys or commands."""
    if not TEXT_MODE or not re.fullmatch("[a-f0-9]{8}", nonce):
        raise ValueError("Invalid virtual typing challenge")
    keys = {" ": (0x2c, 0), "!": (0x1e, 2), "-": (0x2d, 0)}
    for c in "Hid " + nonce + "q":
        if c.isalpha():
            key = (ord(c.lower()) - ord("a") + 4, 2 if c.isupper() else 0)
        elif c.isdigit():
            key = (0x27 if c == "0" else 0x1d + int(c), 0)
        else:
            key = keys[c]
        yield report(*key)
        yield CLEAR
    # Remove the extra q, type X!, move left twice, insert a hyphen, Ctrl+End.
    for usage, modifiers in ((0x2a, 0), (0x1b, 2), keys["!"], (0x50, 0),
                             (0x50, 0), keys["-"], (0x4d, 1)):
        yield report(usage, modifiers)
        yield CLEAR
