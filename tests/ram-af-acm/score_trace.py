"""Validate a complete RAM measurement receipt and summarize its same-frame score pairs."""
import argparse
import codecs
import re
from pathlib import Path
from statistics import median


PHASES = ("coarse", "fine", "verify")
PHASE = r"(coarse|fine|verify)"
PPM = r"(0|[1-9][0-9]{0,7})"
PAIR = re.compile(rf"AF_DIAG phase={PHASE} point=([1-9]) "
                  rf"mean_ppm={PPM} pair_delta_ppm={PPM} ref_mean_ppm={PPM} ref_pair_delta_ppm={PPM}")
TERMINAL = re.compile(rf"AF_DIAG phase={PHASE} reason=([a-z-]+) input=[a-z-]+ lens_api_status=-?[0-9]+ "
                      r"controls=([0-9]+/[0-9]+/[0-9]+) samples=([0-9]+/[0-9]+/[0-9]+) "
                      r"timestamp_rejects=[0-9]+/[0-9]+/[0-9]+")


def parse(rows):
    points = {phase: [] for phase in PHASES}
    last_phase = -1
    terminal = None
    sensor_clean = node_clean = False
    exit_code = None
    for row in rows:
        row = row.rstrip("\r\n")
        if row.startswith("AF_DIAG "):
            if terminal or sensor_clean or exit_code is not None:
                raise ValueError("Extra diagnostic after terminal result")
            if match := PAIR.fullmatch(row):
                phase = match[1]
                values = tuple(map(int, match.groups()[2:]))
                number = int(match[2])
                if (PHASES.index(phase) < last_phase or number != len(points[phase]) + 1
                        or (phase == "verify" and number != 1) or max(values) > 21_250_000):
                    raise ValueError("Duplicate, missing, out-of-order or out-of-range pair")
                points[phase].append(values)
                last_phase = PHASES.index(phase)
            elif terminal_match := TERMINAL.fullmatch(row):
                terminal = terminal_match
            else:
                raise ValueError("Unrecognized diagnostic fields")
        elif re.fullmatch(r"AF_CLEANUP mode=--rear-af rear=suspended sensor_active_ms_delta=[0-9]+ exit=[0-9]+", row):
            if sensor_clean or exit_code is not None:
                raise ValueError("Duplicate or misplaced sensor cleanup")
            sensor_clean = True
        elif row == "AF_ALLOCATOR cleanup=1 original_unchanged=1":
            if not sensor_clean or node_clean or exit_code is not None:
                raise ValueError("Misplaced allocator cleanup")
            node_clean = True
        elif row.startswith("AF1 END "):
            if not node_clean or exit_code is not None or not re.fullmatch(r"AF1 END rc=[0-9]{1,3}", row):
                raise ValueError("Missing cleanup or duplicate terminal receipt")
            exit_code = int(row.split("=")[-1])
    if not terminal or exit_code is None:
        raise ValueError("Missing terminal diagnostic or complete RAM receipt")
    controls = list(map(int, terminal[3].split("/")))
    samples = list(map(int, terminal[4].split("/")))
    for i, phase in enumerate(PHASES):
        if samples[i] > 2 * controls[i] or controls[i] > (1 if phase == "verify" else 9):
            raise ValueError("Terminal control/sample counts out of range")
        if len(points[phase]) != samples[i] // 2:
            raise ValueError(f"Missing score pairs for {phase}, expected {samples[i] // 2}")
        if i > PHASES.index(terminal[1]) and controls[i]:
            raise ValueError("Counts after terminal phase")
    if not any(points.values()):
        raise ValueError("No completed pair available to compare")
    return points, terminal[1], terminal[2], exit_code


def summarize(rows):
    points, phase, reason, exit_code = parse(rows)
    yield f"AF_TRACE terminal_phase={phase} reason={reason} process_rc={exit_code}"
    for phase, pairs in points.items():
        if not pairs:
            continue
        for offset, channel in ((0, "production"), (2, "reference")):
            means = [pair[offset] for pair in pairs]
            deltas = [pair[offset + 1] for pair in pairs]
            low, high = min(means), max(means)
            summary = (f"AF_TRACE phase={phase} channel={channel} pairs={len(pairs)} "
                       f"min_ppm={low} max_ppm={high} span_ppm={high-low} "
                       f"median_pair_delta_ppm={median(deltas):.1f} max_pair_delta_ppm={max(deltas)}")
            if phase == "coarse":
                summary += (f" floor_margin_ppm={high-25000} "
                            f"relative_margin_ppm={(100*high - 112*low)/100:.2f}")
            yield summary


def read_receipt(path):
    # Windows PowerShell 5.1 Tee-Object writes UTF-16; PowerShell 7 writes UTF-8.
    with path.open("rb") as stream:
        prefix = stream.read(2)
    encoding = "utf-16" if prefix in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE) else "utf-8-sig"
    with path.open(encoding=encoding) as stream:
        yield from stream


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    try:
        for line in summarize(read_receipt(args.receipt)):
            print(line)
    except ValueError as exc:
        parser.exit(1, f"Score trace unavailable: {exc}\n")
