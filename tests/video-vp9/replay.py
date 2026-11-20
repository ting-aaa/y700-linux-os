"""Compile the patched dequeue path with deterministic hardware events."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("meson_build", type=Path)
    args.add_argument("new_output", type=Path)
    opts = args.parse_args()
    obj, out = opts.meson_build.resolve(), opts.new_output.resolve()
    unit, = (e for e in json.loads((obj / "compile_commands.json").read_text())
             if Path(e["file"]).name == "gstv4l2bufferpool.c")
    out.mkdir()
    src = (obj / unit["file"]).read_text()
    start = src.index("static GstFlowReturn\ngst_v4l2_buffer_pool_dqbuf_once (")
    end = src.index("static GstFlowReturn\ngst_v4l2_buffer_pool_acquire_buffer (", start)
    body = src[start:end]
    # Keep the real pool accounting, GstBuffers, GSignals, final frame flags
    # and flow returns. Replace only polling, kernel dequeue and requeue.
    for real, simulated in (("gst_v4l2_buffer_pool_poll", "fixture_poll"),
                            ("gst_v4l2_allocator_dqbuf", "fixture_dqbuf"),
                            ("gst_v4l2_buffer_pool_complete_release_buffer", "fixture_requeue")):
        if real not in body:
            raise SystemExit(f"missing expected call to {real}")
        body = body.replace(real + " (", simulated + " (")
    declarations = """
static GstFlowReturn fixture_poll (GstV4l2BufferPool *, gboolean);
static GstFlowReturn fixture_dqbuf (GstV4l2Allocator *, GstV4l2MemoryGroup **);
static void fixture_requeue (GstBufferPool *, GstBuffer *, gboolean);
"""
    fixture = out / "replay.c"
    fixture.write_text(src[:start] + declarations + body + src[end:] +
                       Path(__file__).with_name("replay.c").read_text())
    cmd = shlex.split(unit["command"])
    test_obj = out / "replay.o"
    for flag, value in [("-c", fixture), ("-o", test_obj), ("-MF", out / "replay.d"), ("-MQ", test_obj)]:
        cmd[cmd.index(flag) + 1] = str(value)
    subprocess.run(cmd, cwd=obj, check=True)
    target = "sys/v4l2/libgstvideo4linux2.so"
    commands = subprocess.check_output([os.getenv("NINJA", "ninja"), "-t", "commands", target], cwd=obj, text=True)
    link = [i for i in shlex.split(commands.splitlines()[-1]) if i != "-shared" and not i.startswith("-Wl,-soname,")]
    link[link.index("-o") + 1] = str(out / "replay")
    link[link.index(unit["output"])] = str(test_obj)
    subprocess.run(link, cwd=obj, check=True)


if __name__ == "__main__":
    main()
