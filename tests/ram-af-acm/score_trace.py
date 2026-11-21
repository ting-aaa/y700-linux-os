"""Validate a complete RAM measurement receipt and summarize its same-frame score pairs."""
import argparse
import codecs
from dataclasses import dataclass
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
NO_TRIGGER = "preview_did_not_stabilize_no_trigger"
DECIMAL = r"[0-9]+\.[0-9]{4}"
PREVIEW = re.compile(
    rf"AF_PREVIEW frames=(?P<frames>[0-9]+) ready=0 stable=[01] sharpness={DECIMAL} "
    rf"brightness=(?P<brightness>{DECIMAL}) clipped=(?P<clipped>{DECIMAL}) spread={DECIMAL} "
    rf"gain_min={DECIMAL} gain_max={DECIMAL} time_min_us={DECIMAL} time_max_us={DECIMAL}")
SENSOR_CLEAN = re.compile(r"AF_CLEANUP mode=--rear-af rear=suspended sensor_active_ms_delta=[0-9]+ exit=([0-9]+)")


@dataclass
class Trace:
    points: dict
    phase: str
    reason: str
    exit_code: int
    last_preview: dict | None = None


def preview_only(rows):
    # The dev12.13 client accepts 80 windows of eight frames after 24 warmup frames.
    # On timeout it releases the camera in the exception handler before printing AF_ERROR.
    if rows[-1:] == ["AF1 RETURN acknowledged=1"]:
        rows = rows[:-1]
    tail = rows[-5:]
    if (len(tail) != 5 or tail[:2] != ["AF_CONFIG step=release rc=0", f"AF_ERROR reason={NO_TRIGGER}"]
            or not (clean := SENSOR_CLEAN.fullmatch(tail[2])) or clean[1] != "1"
            or tail[3:] != ["AF_ALLOCATOR cleanup=1 original_unchanged=1", "AF1 END rc=1"]):
        raise ValueError("Missing or contradictory preview termination, release, cleanup or exit code")
    windows = []
    for row in rows[:-5]:
        if row.startswith("AF_PREVIEW "):
            sample = PREVIEW.fullmatch(row)
            if (not sample or int(sample["frames"]) != 32 + 8 * len(windows)
                    or float(sample["brightness"]) > 255 or float(sample["clipped"]) > 1):
                raise ValueError("Missing, invalid or already-ready preview window")
            windows.append(sample.groupdict())
        elif row.startswith(("AF_EXPOSURE ", "AF_CONFIG_RESOURCE ", "AF1 READY ", "AF1 DONE ", "AF1 RUNNING ")):
            continue
        elif row.startswith("AF_CONFIG ") and not row.startswith("AF_CONFIG step=release"):
            continue
        else:
            raise ValueError("Unexpected evidence in a preview-only measurement")
    if len(windows) != 80:
        raise ValueError("Missing bounded preview windows")
    return Trace({}, "preview", NO_TRIGGER, 1, windows[-1])


def parse(rows):
    rows = [row.rstrip("\r\n") for row in rows if row.strip()]
    if f"AF_ERROR reason={NO_TRIGGER}" in rows:
        return preview_only(rows)
    points = {phase: [] for phase in PHASES}
    last_phase = -1
    terminal = None
    sensor_code = None
    node_clean = False
    exit_code = None
    for row in rows:
        row = row.rstrip("\r\n")
        if row.startswith("AF_DIAG "):
            if terminal or sensor_code is not None or exit_code is not None:
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
        elif clean := SENSOR_CLEAN.fullmatch(row):
            if not terminal or sensor_code is not None or exit_code is not None:
                raise ValueError("Duplicate or misplaced sensor cleanup")
            sensor_code = int(clean[1])
        elif row == "AF_ALLOCATOR cleanup=1 original_unchanged=1":
            if sensor_code is None or node_clean or exit_code is not None:
                raise ValueError("Misplaced allocator cleanup")
            node_clean = True
        elif row.startswith("AF1 END "):
            if not node_clean or exit_code is not None or not re.fullmatch(r"AF1 END rc=[0-9]{1,3}", row):
                raise ValueError("Missing cleanup or duplicate terminal receipt")
            exit_code = int(row.split("=")[-1])
            if exit_code != sensor_code:
                raise ValueError("Sensor cleanup and end receipt disagree on process exit")
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
    return Trace(points, terminal[1], terminal[2], exit_code)


def summarize(rows):
    trace = parse(rows)
    yield f"AF_TRACE terminal_phase={trace.phase} reason={trace.reason} process_rc={trace.exit_code}"
    if trace.last_preview:
        last = trace.last_preview
        yield (f"AF_TRACE preview_frames={last['frames']} af_triggered=0 score_pairs=0 "
               f"last_brightness={last['brightness']} last_clipped={last['clipped']}")
    for phase, pairs in trace.points.items():
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
