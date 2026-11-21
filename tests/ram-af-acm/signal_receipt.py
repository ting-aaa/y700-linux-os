"""Validate the bounded numeric protocol for one matched HI1339 exposure."""

import argparse
import re
import sys


Q4 = r"(?:0|[1-9][0-9]{0,3})\.[0-9]{4}"
FRAC = r"(?:0\.[0-9]{4}|1\.0000)"
PAIR = re.compile(rf"SIGNAL_PAIR sequence=([0-9]{{1,10}}) time_us=([0-9]{{1,7}}) analogue_gain=({Q4}) crop_x=1784 crop_y=1320")
RAW = re.compile(rf"SIGNAL_RAW site=(R|Gr|Gb|B) n=(21[26]0) mean10=({Q4}) pedestal10=([0-9]{{1,4}}) at_or_below_pedestal=({FRAC}) near_white=({FRAC})")
RGB = re.compile(rf"SIGNAL_RGB channel=([RGB]) n=8560 mean8=({Q4}) near_black=({FRAC}) near_white=({FRAC})")
DONE = "SIGNAL_DONE pairs=1 measured_after_warmup=24 af_commands=0"
FAIL = "SIGNAL_FAILURE incomplete=1"
SUSPEND = re.compile(r"AF_CLEANUP mode=--rear-signal rear=suspended sensor_active_ms_delta=([0-9]{1,6}) exit=0")
ALLOC = "AF_ALLOCATOR cleanup=1 original_unchanged=1"
VIRTUAL = "SIGNAL_TEST synthetic=1 camera_access=0"


def valid_row(index, line, virtual):
    if index == 0:
        m = PAIR.fullmatch(line)
        return bool(m and int(m[1]) <= 0xFFFFFFFF and 0 < int(m[2]) <= 655350 and 1 <= float(m[3]) <= 16)
    if 1 <= index <= 4:
        m = RAW.fullmatch(line)
        if not m or m[1] != ("R", "Gr", "Gb", "B")[index - 1]:
            return False
        return (int(m[2]) == (2160, 2120, 2160, 2120)[index - 1] and float(m[3]) <= 1023
                and int(m[4]) <= 1023)
    if 5 <= index <= 7:
        m = RGB.fullmatch(line)
        return bool(m and m[1] == "RGB"[index - 5] and float(m[2]) <= 255
                    and float(m[3]) + float(m[4]) <= 1.00011)
    if index == 8:
        return line == DONE
    if index == 9:
        return line == VIRTUAL if virtual else bool(SUSPEND.fullmatch(line))
    return index == 10 and not virtual and line == ALLOC


def complete(rows, virtual):
    return len(rows) == (10 if virtual else 11) and all(valid_row(i, row, virtual) for i, row in enumerate(rows))


def filter_output(stream, virtual):
    rows = []
    malformed = False
    for raw in stream:
        # The executable and wrapper are pinned. Omit free-form driver diagnostics entirely.
        if not raw.startswith(("SIGNAL_", "AF_CLEANUP ", "AF_ALLOCATOR ")):
            continue
        line = raw.rstrip("\r\n")
        if len(line) > 240 or len(rows) >= 11 or not valid_row(len(rows), line, virtual):
            malformed = True
        else:
            rows.append(line)
    if malformed or not complete(rows, virtual):
        print(FAIL)
        return 1
    print(*rows, sep="\n")
    return 0


def synthetic():
    # Guest transport fixture. Values are deliberately artificial, with an explicit virtual marker.
    print("SIGNAL_PAIR sequence=24 time_us=33280 analogue_gain=16.0000 crop_x=1784 crop_y=1320")
    for site, count, mean in zip(("R", "Gr", "Gb", "B"), (2160, 2120, 2160, 2120), (803, 402, 402, 133)):
        print(f"SIGNAL_RAW site={site} n={count} mean10={mean:.4f} pedestal10=64 at_or_below_pedestal=0.0000 near_white=0.0000")
    for channel, mean in zip("RGB", (223, 150, 67)):
        print(f"SIGNAL_RGB channel={channel} n=8560 mean8={mean:.4f} near_black=0.0000 near_white=0.0000")
    print(DONE, VIRTUAL, sep="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("filter", "virtual-fixture"))
    parser.add_argument("--virtual", action="store_true")
    options = parser.parse_args()
    if options.operation == "virtual-fixture":
        synthetic()
    else:
        sys.exit(filter_output(sys.stdin, options.virtual))
