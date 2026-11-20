"""Repeat each short synthetic pattern to keep the display observer independent of startup latency."""
import argparse
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    args = parser.parse_args()
    if not args.ffmpeg:
        import imageio_ffmpeg
        args.ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    args.output.mkdir(parents=True, exist_ok=False)
    for name in ("vp9.webm", "h264.mp4", "hevc.mp4"):
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-stream_loop", "7",
                        "-i", str(args.original / name), "-map", "0:v:0", "-c:v", "copy", "-fflags", "+bitexact",
                        str(args.output / name)], check=True, timeout=30)


if __name__ == "__main__":
    main()
