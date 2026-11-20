"""Prepare independent I420 frame references for the 1080p desktop player fixtures."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("clips", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    args = parser.parse_args()
    if not args.ffmpeg:
        import imageio_ffmpeg
        args.ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    args.output.mkdir(parents=True, exist_ok=False)
    for name in ("h264.mp4", "hevc.mp4", "vp9.webm"):
        clip = args.clips / name
        folder = args.output / clip.stem
        folder.mkdir()
        report = subprocess.check_output([
            args.ffmpeg, "-v", "error", "-nostdin", "-hwaccel", "none", "-threads", "1",
            "-i", str(clip), "-map", "0:v:0", "-fps_mode", "passthrough", "-pix_fmt", "yuv420p",
            "-f", "framehash", "-hash", "sha256", "-",
        ], text=True, timeout=45)
        if not re.search(r"^#dimensions\s+0:\s*1920x1080$", report, re.M):
            raise ValueError(f"Unexpected stream geometry in {clip}")
        hashes = [line.rsplit(",", 1)[-1].strip() for line in report.splitlines() if not line.startswith("#")]
        if len(hashes) != 48 or not all(re.fullmatch("[0-9a-f]{64}", h) for h in hashes):
            raise ValueError(f"Incomplete software frame hashes for {clip}")
        shutil.copyfile(clip, folder / ("clip" + clip.suffix))
        (folder / "geometry").write_text("1920 1080\n", encoding="ascii", newline="\n")
        (folder / "reference.sha256").write_text("\n".join(hashes) + "\n", encoding="ascii", newline="\n")
        print(f"{name} reference_frames={len(hashes)} geometry=1920x1080")


if __name__ == "__main__":
    main()
