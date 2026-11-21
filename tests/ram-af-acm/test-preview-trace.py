"""Validate dev12.13 preview timeout receipts with Windows or POSIX Python."""
import argparse
from pathlib import Path
from score_trace import read_receipt, summarize


WINDOWS = [
    f"AF_PREVIEW frames={frame} ready=0 stable=0 sharpness=1.0443 brightness=1.7162 clipped=0.9125 "
    "spread=0.0451 gain_min=16.0000 gain_max=16.0000 time_min_us=33280.0000 time_max_us=33280.0000"
    for frame in range(32, 665, 8)
]
END = ["AF_CONFIG step=release rc=0", "AF_ERROR reason=preview_did_not_stabilize_no_trigger",
       "AF_CLEANUP mode=--rear-af rear=suspended sensor_active_ms_delta=25117 exit=1",
       "AF_ALLOCATOR cleanup=1 original_unchanged=1", "AF1 END rc=1"]
SUMMARY = ["AF_TRACE terminal_phase=preview reason=preview_did_not_stabilize_no_trigger process_rc=1",
           "AF_TRACE preview_frames=664 af_triggered=0 score_pairs=0 last_brightness=1.7162 last_clipped=0.9125"]


def check(actual):
    assert list(summarize([*WINDOWS, *END])) == SUMMARY
    assert list(summarize([*WINDOWS, *END, "AF1 RETURN acknowledged=1"])) == SUMMARY
    rejected = []
    for i in range(len(END)):
        rejected.append([*WINDOWS, *END[:i], *END[i+1:]])
        rejected.append([*WINDOWS, *END[:i], END[i], *END[i:]])
        if i:
            tail = END.copy()
            tail[i-1], tail[i] = tail[i], tail[i-1]
            rejected.append([*WINDOWS, *tail])
    for i, old, new in ((0, "rc=0", "rc=-1"), (2, "suspended", "active"), (2, "exit=1", "exit=0"),
                        (3, "unchanged=1", "unchanged=0"), (4, "rc=1", "rc=0")):
        tail = END.copy()
        tail[i] = tail[i].replace(old, new)
        rejected.append([*WINDOWS, *tail])
    for conflict in ("AF_SCAN scanning_frames=0 controls=1 state=failed", "AF_DIAG phase=coarse point=1",
                     "AF_RESULT verdict=inconclusive", "AF_ERROR reason=frame_timeout"):
        rejected.append([*WINDOWS, conflict, *END])
    rejected.extend(([*WINDOWS[:-1], *END], [*WINDOWS, WINDOWS[-1], *END],
                     [*WINDOWS[:-1], WINDOWS[-1].replace("ready=0", "ready=1"), *END],
                     [*WINDOWS, *END, "AF1 RETURN acknowledged=0"]))
    for case in rejected:
        try:
            list(summarize(case))
        except ValueError:
            continue
        raise AssertionError("Corrupted preview receipt accepted")
    print(f"PREVIEW_TRACE valid=2 rejected={len(rejected)}")
    if actual:
        assert list(summarize(read_receipt(actual))) == SUMMARY
        print("PREVIEW_TRACE_PHYSICAL replay=1 frames=664 af_triggered=0 score_pairs=0 process_rc=1")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--physical-receipt", type=Path)
    check(parser.parse_args().physical_receipt)
