"""Make a tiny software-encoded video corpus and matching linear Iris-layout test data."""
import argparse
from pathlib import Path
import shutil
import subprocess

WIDTH, HEIGHT = 192, 112
STRIDE, SCANLINES = 256, 128
COLOURS = [(81, 90, 240), (145, 54, 34), (41, 240, 110)]
FRAMES = 6


def make_raw(directory):
    packed = bytearray()
    padded = bytearray()
    for index in range(FRAMES):
        left, right = COLOURS[index % 3], COLOURS[(index + 1) % 3]
        y = bytes([left[0]]) * (WIDTH // 2) + bytes([right[0]]) * (WIDTH // 2)
        u = bytes([left[1]]) * (WIDTH // 4) + bytes([right[1]]) * (WIDTH // 4)
        v = bytes([left[2]]) * (WIDTH // 4) + bytes([right[2]]) * (WIDTH // 4)
        packed.extend(y * HEIGHT + u * (HEIGHT // 2) + v * (HEIGHT // 2))
        uv = bytes(value for pair in zip(u, v) for value in pair)
        for row, visible, stored in ((y, HEIGHT, SCANLINES), (uv, HEIGHT // 2, SCANLINES // 2)):
            padded.extend((row + b"\xa5" * (STRIDE - WIDTH)) * visible)
            padded.extend(b"\xa5" * STRIDE * (stored - visible))
    (directory / "expected.i420").write_bytes(packed)
    (directory / "padded.nv12").write_bytes(padded)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("directory", type=Path)
    cli.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    args = cli.parse_args()
    if not args.ffmpeg:
        import imageio_ffmpeg
        args.ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    destination = args.directory.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    make_raw(destination)

    def encode(arguments):
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-n", *arguments],
                       cwd=destination, check=True, timeout=35)

    raw = ["-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", f"{WIDTH}x{HEIGHT}",
           "-framerate", "2", "-i", "expected.i420", "-an", "-threads", "1"]
    colour = ["-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m"]
    encode(raw + ["-c:v", "libx264", "-profile:v", "baseline", "-crf", "16", "-bf", "0",
                  "-x264-params", "aud=1:repeat-headers=1:keyint=12", *colour, "-movflags", "+faststart", "h264.mp4"])
    encode(raw + ["-c:v", "libx265", "-profile:v", "main", "-x265-params",
                  "log-level=error:pools=none:frame-threads=1:bframes=0:keyint=12", *colour, "-tag:v", "hvc1",
                  "-movflags", "+faststart", "hevc.mp4"])
    encode(raw + ["-c:v", "libvpx-vp9", "-lossless", "1", "-row-mt", "0", "-lag-in-frames", "0",
                  *colour, "-fflags", "+bitexact", "vp9.webm"])
    for name, ext, bsf in (("h264.mp4", "h264", "h264_mp4toannexb"), ("hevc.mp4", "hevc", "hevc_mp4toannexb"),
                           ("vp9.webm", "vp9", None)):
        encoded = ["-i", name, "-map", "0:v:0", "-c:v", "copy"]
        if bsf:
            encoded += ["-bsf:v", bsf]
        encode(encoded + ["-f", "image2", f"au-%02d.{ext}"])
        assert len(list(destination.glob("au-*." + ext))) == FRAMES


if __name__ == "__main__":
    main()
