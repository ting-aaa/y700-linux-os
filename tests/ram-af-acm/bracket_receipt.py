"""Bounded numeric rows from four metadata-confirmed frames in one HI1339 run."""
import argparse
from pathlib import Path
import re
import sys

# The isolated guest interpreter runs directly from the root-owned RAM payload.
if __name__ == "__main__" and sys.flags.isolated:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import signal_receipt as signal


POINTS = ((2000, 1), (32000, 1), (32000, 8), (2000, 1))
DONE = "BRACKET_DONE pairs=4 stable_frames=4 auto_requests_completed=4 af_commands=0"
VIRTUAL = "BRACKET_TEST synthetic=1 camera_access=0 isolated_ipa=1"
SUSPEND = re.compile(r"AF_CLEANUP mode=--rear-bracket rear=suspended sensor_active_ms_delta=([0-9]{1,6}) exit=([0-9]{1,3})")
REASONS = ("incomplete", "malformed", "camera_manager", "no_rear_hi1339", "rear_busy_or_access_denied",
           "no_manual_bracket_controls", "bracket_applied_timeout", "bracket_auto_timeout",
           "signal_metadata_missing", "frame_timeout", "capture_limit", "capture_cancelled", "bad_frame",
           "stale_frame", "map_failed", "dma_read_sync_failed", "stop_failed", "release_failed")
FAILURE = re.compile(r"BRACKET_FAILURE code=([0-9]{1,2}) complete_pairs=([0-4]) rear_suspended=([01]) allocator_clean=([01])")


def is_failure(line):
    m = FAILURE.fullmatch(line)
    return bool(m and int(m[1]) < len(REASONS))


def valid_row(index, line, virtual):
    if index < 36:
        step, offset = divmod(index, 9)
        exposure, gain = POINTS[step]
        if offset == 0:
            return line == f"BRACKET_STEP index={step + 1} target_us={exposure} target_gain={gain}"
        if not signal.valid_row(offset - 1, line, virtual):
            return False
        if offset == 1:
            pair = signal.PAIR.fullmatch(line)
            return int(pair[2]) == exposure and float(pair[3]) == gain
        return True
    if index == 36:
        return line == DONE
    if index == 37:
        if virtual:
            return line == VIRTUAL
        m = SUSPEND.fullmatch(line)
        return bool(m and int(m[1]) > 0 and m[2] == "0")
    return index == 38 and not virtual and line == signal.ALLOC


def complete(rows, virtual):
    if len(rows) != (38 if virtual else 39) or not all(valid_row(i, r, virtual) for i, r in enumerate(rows)):
        return False
    seq = [int(signal.PAIR.fullmatch(rows[i])[1]) for i in (1, 10, 19, 28)]
    return all(a < b for a, b in zip(seq, seq[1:]))


def filter_output(stream, virtual):
    rows = []
    malformed = suspended = clean = saw_cleanup = False
    code = 0
    for raw in stream:
        if not raw.startswith(("BRACKET_", "SIGNAL_", "AF_ERROR ", "AF_CLEANUP ", "AF_ALLOCATOR ")):
            continue
        line = raw.rstrip("\r\n")
        if line.startswith("AF_ERROR "):
            reason = line.removeprefix("AF_ERROR reason=")
            if reason in REASONS:
                code = REASONS.index(reason)
            continue
        if line.startswith("AF_CLEANUP "):
            if saw_cleanup or virtual:
                malformed = True
            saw_cleanup = True
            suspended = bool(SUSPEND.fullmatch(line))
            if not suspended:
                malformed = True
                continue
            if not line.endswith(" exit=0") or len(rows) != 37:
                continue
        if line == signal.ALLOC:
            if clean or virtual:
                malformed = True
            clean = True
            if len(rows) != 38:
                continue
        if len(line) <= 240 and valid_row(len(rows), line, virtual):
            rows.append(line)
        else:
            malformed = True
    if not code and not malformed and complete(rows, virtual):
        print(*rows, sep="\n")
        return 0
    if malformed or (len(rows) >= 36 and not code and len(rows) == (38 if virtual else 39)):
        code = REASONS.index("malformed")
    print(f"BRACKET_FAILURE code={code} complete_pairs={min(4, len(rows) // 9)}"
          f" rear_suspended={int(suspended)} allocator_clean={int(clean)}")
    return 1


def synthetic():
    for i, (exposure, gain) in enumerate(POINTS):
        print(f"BRACKET_STEP index={i + 1} target_us={exposure} target_gain={gain}")
        print(f"SIGNAL_PAIR sequence={8 + i * 7} time_us={exposure} analogue_gain={gain:.4f} crop_x=1784 crop_y=1320")
        for site, n in zip(("R", "Gr", "Gb", "B"), (2160, 2120, 2160, 2120)):
            print(f"SIGNAL_RAW site={site} n={n} mean10=256.0000 pedestal10=64 at_or_below_pedestal=0.0000 near_white=0.0000")
        for channel in "RGB":
            print(f"SIGNAL_RGB channel={channel} n=8560 mean8=64.0000 near_black=0.0000 near_white=0.0000")
    print(DONE, VIRTUAL, sep="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("filter", "virtual-fixture"))
    parser.add_argument("--virtual", action="store_true")
    args = parser.parse_args()
    if args.operation == "virtual-fixture":
        synthetic()
    else:
        sys.exit(filter_output(sys.stdin, args.virtual))
