"""Check only the virtual USB fixture's generated signal, entirely in memory."""
from array import array
from contextlib import ExitStack
import math
import os
from pathlib import Path
import subprocess
import sys
from threading import Event

from session import graph, record, wait_for


def desktop():
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    with ExitStack() as processes:
        def start(program):
            output = processes.enter_context((runtime / (program + ".log")).open("w"))
            child = subprocess.Popen([program], stdout=output, stderr=output)
            processes.callback(child.wait, 5)
            processes.callback(child.terminate)
        start("pipewire")
        wait_for((runtime / "pipewire-0").is_socket, "PipeWire socket")
        start("wireplumber")
        start("pipewire-pulse")
        wait_for((runtime / "pulse/native").is_socket, "Pulse server socket")
        def source():
            nodes = graph()
            usb = [n for n in nodes if n.get("api.alsa.pcm.card") in (0, "0")]
            sources = [n for n in usb if n.get("media.class") == "Audio/Source"]
            sinks = [n for n in usb if n.get("media.class") == "Audio/Sink"]
            if len(sources) == len(sinks) == 1:
                name = sources[0]["node.name"]
                assert name.startswith("alsa_input.usb-") and not name.endswith(".monitor"), name
                assert sources[0]["api.alsa.pcm.stream"] == "capture"
                return name
        name = wait_for(source, "USB microphone and playback sink")
        release = Event()
        release.set()
        samples = record(name.encode(), Event(), release)
        assert samples is not None and len(samples) == 96000
        print("UAC_DESKTOP user=ordinary source=usb_alsa_capture sink=usb_alsa_playback monitor=0")
        return samples[::2]


def alsa():
    data = subprocess.check_output(["arecord", "-q", "-D", "hw:0,0", "-t", "raw", "-c1",
                                    "-f", "S16_LE", "-r48000", "--period-size=480", "--buffer-size=9600", "-d1"], timeout=14)
    return array("h", data)


def amplitude(samples, frequency):
    # Short blocks avoid cancelling phase across a scheduling discontinuity.
    angles = [2 * math.pi * frequency * t / 12000 for t in range(600)]
    sine = [math.sin(a) for a in angles]
    cosine = [math.cos(a) for a in angles]
    scores = []
    for start in range(0, 48000, 2400):
        block = samples[start:start + 2400:4]
        scores.append(math.hypot(sum(x*y for x,y in zip(block,sine)),
                                 sum(x*y for x,y in zip(block,cosine))) / len(block))
    return sorted(scores)[len(scores)//2]


if __name__ == "__main__":
    assert "y700.test_uac=1" in Path("/proc/cmdline").read_text().split()
    assert sys.byteorder == "little" and os.getuid() != 0
    mode, = sys.argv[1:]
    samples = {"alsa": alsa, "desktop": desktop}[mode]()
    assert len(samples) == 48000
    signal = amplitude(samples, 440)
    control = max(amplitude(samples, 240), amplitude(samples, 840))
    assert signal > 100 and signal > 8 * max(1, control), (signal, control)
    print(f"UAC_PCM api={mode} frames={len(samples)} hz=48000 tone440={signal:.0f} control_max={control:.0f}")
