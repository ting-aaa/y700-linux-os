"""PC replay of libcamera log filtering, the Windows host ACK and numerical trace extraction."""
import argparse
import contextlib
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tempfile

from host import result
from score_trace import parse, read_receipt, summarize


HERE = Path(__file__).resolve().parent
ENDING = ["AF_CLEANUP mode=--rear-af rear=suspended sensor_active_ms_delta=1234 exit=0",
          "AF_ALLOCATOR cleanup=1 original_unchanged=1", "AF1 END rc=0"]


class Wire:
    def __init__(self, rows):
        self.rows = iter([*rows, "AF1 RETURN acknowledged=1"])
        self.commands = []

    def line(self):
        return next(self.rows)

    def send(self, cmd):
        self.commands.append(cmd)


def through_filter(text, root):
    proc = subprocess.run([shutil.which("bash"), (root / "filter.sh").as_posix()], input=text.encode("ascii"),
                          capture_output=True, check=True)
    return proc.stdout.decode("ascii").splitlines()


def received(rows):
    full = [*rows, *ENDING]
    wire = Wire(full)
    cap = io.StringIO()
    with contextlib.redirect_stdout(cap):
        assert result(wire, "a" * 32, False, False, acknowledge=True) == 0
    digest = hashlib.sha256(("\n".join(full) + "\n").encode("ascii")).hexdigest()
    assert wire.commands == ["RESULT " + "a" * 32, "ACK " + "a" * 32 + " " + digest]
    return cap.getvalue().splitlines()


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--library-log", type=Path, help="One libcamera synthetic scan through its terminal diagnostic")
    args = cli.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        shutil.copyfile(HERE / "filter-pairs.sh", root / "filter.sh")
        shutil.copyfile(HERE / "filter.sh", root / "filter-aggregates.sh")
        prefix = "[0:00:02.123] [42] DEBUG Y700Af simple.cpp:100 "
        pairs = [f"AF_DIAG phase=coarse point={i+1} mean_ppm={55000+i*750} pair_delta_ppm=25 "
                 f"ref_mean_ppm={45000+i*1200} ref_pair_delta_ppm=100" for i in range(9)]
        diag = ("AF_DIAG phase=coarse reason=flat-contrast input=none lens_api_status=0 "
                "controls=9/0/0 samples=18/0/0 timestamp_rejects=18/0/0")
        rejected = [pairs[0] + " dac=123", pairs[0].replace("coarse", "verify").replace("point=1", "point=2"),
                    pairs[0].replace("55000", "21250001"), pairs[0].replace("55000", "-1"),
                    pairs[0].split(" ref_mean")[0], diag + " private=secret"]
        filtered = through_filter("\n".join(prefix + x for x in [*pairs, *rejected, diag]) + "\n", root)
        assert filtered == [*pairs, diag]
        receipt = received(filtered)
        summary = list(summarize(receipt))
        for encoding in ("utf-8", "utf-8-sig", "utf-16"):
            saved = root / "measurement.log"
            saved.write_text("\r\n".join(receipt), encoding=encoding)
            assert list(summarize(read_receipt(saved))) == summary
        assert "relative_margin_ppm=-600.00" in summary[1] and "span_ppm=6000" in summary[1]
        assert "relative_margin_ppm=4200.00" in summary[2] and "span_ppm=9600" in summary[2]
        focused = ("AF_DIAG phase=verify reason=focused input=none lens_api_status=0 "
                   "controls=9/9/1 samples=18/18/2 timestamp_rejects=9/9/1")
        complete = [*pairs, *(line.replace("coarse", "fine") for line in pairs),
                    pairs[0].replace("coarse", "verify"), focused]
        assert through_filter("\n".join(complete) + "\n", root) == complete
        counts = parse(received(complete)).points
        assert [len(points) for points in counts.values()] == [9, 9, 1]
        for invalid in ([*receipt[1:]], [receipt[0], *receipt], receipt[:-2],
                        [*pairs[:8], diag, *ENDING], [pairs[1], pairs[0], *receipt[2:]],
                        [*pairs, diag, *ENDING[1:]], [*pairs, rejected[0], diag, *ENDING]):
            try:
                parse(invalid)
            except ValueError:
                continue
            raise AssertionError("Invalid or incomplete trace accepted")
        print("SCORE_TRACE_TEST flat_pairs=9 focused_pairs=19 compared_channels=2 filter_rejections=6 "
              "trace_rejections=7 host_ack_hash=1 windows_encodings=3")
        if args.library_log:
            actual = through_filter(args.library_log.read_text(), root)
            diags = [line for line in actual if line.startswith("AF_DIAG ")]
            actual_receipt = received(diags)
            points = parse(actual_receipt).points
            assert len(points["coarse"]) == 9
            print("SCORE_TRACE_LIBRARY_REPLAY coarse_pairs=9 compared_channels=2 host_ack_hash=1")
            print("\n".join(summarize(actual_receipt)))
