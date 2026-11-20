"""Observe the shipped session manager and read its synthetic microphone via the Pulse API."""
from array import array
from concurrent.futures import ThreadPoolExecutor
import ctypes as C
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from threading import Event
import wave


class SampleSpec(C.Structure):
    _fields_ = [("format", C.c_int), ("rate", C.c_uint32), ("channels", C.c_uint8)]


def record(source, ready, release, allow_absent=False):
    pulse = C.CDLL("libpulse-simple.so.0")
    pulse.pa_simple_new.argtypes = [C.c_char_p, C.c_char_p, C.c_int, C.c_char_p, C.c_char_p,
                                    C.POINTER(SampleSpec), C.c_void_p, C.c_void_p, C.POINTER(C.c_int)]
    pulse.pa_simple_new.restype = C.c_void_p
    pulse.pa_simple_read.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_int)]
    pulse.pa_simple_free.argtypes = [C.c_void_p]
    spec = SampleSpec(3, 48000, 2)  # PA_SAMPLE_S16LE
    error = C.c_int()
    stream = pulse.pa_simple_new(None, b"Y700 test client", 2, source, b"Synthetic signal",
                                 C.byref(spec), None, None, C.byref(error))
    if not stream and allow_absent and error.value == 5:  # PA_ERR_NOENTITY
        ready.set()
        return None
    assert stream, (source, error.value)
    try:
        data = C.create_string_buffer(48000 * 4)
        assert pulse.pa_simple_read(stream, data, len(data), C.byref(error)) == 0, error.value
        ready.set()
        assert release.wait(12), "Capture observer did not finish"
        return array("h", data.raw)
    finally:
        pulse.pa_simple_free(stream)


def tones(samples, channel):
    # Compare Fourier amplitudes in short blocks; drop startup silence and xrun gaps.
    periods = (128, 48, 32)  # 375 Hz playback, 1 kHz left mic, 1.5 kHz right mic
    scores = [0.0] * len(periods)
    for start in range(0, len(samples) // 2 - 768, 768):
        block = samples[2 * start + channel:2 * (start + 768):2]
        for i, period in enumerate(periods):
            phases = [sum(block[pos::period]) for pos in range(period)]
            a = sum(value * math.sin(2 * math.pi * pos / period) for pos, value in enumerate(phases))
            b = sum(value * math.cos(2 * math.pi * pos / period) for pos, value in enumerate(phases))
            scores[i] += math.hypot(a, b) / len(block)
    return scores


def assert_tones(samples, wanted):
    for channel, index in enumerate(wanted):
        energy = tones(samples, channel)
        assert energy[index] > max(60, 5 * max(x for i, x in enumerate(energy) if i != index)), (channel, energy)


def graph():
    objects = json.loads(subprocess.check_output(["pw-dump"], timeout=5))
    return [obj["info"]["props"] for obj in objects if obj["type"].endswith(":Node")]


def controls():
    controls = subprocess.check_output(["amixer", "-c", "LenovoY700", "contents"], text=True)
    values = {}
    for block in controls.split("numid=")[1:]:
        name = re.search(r"name='([^']+)'", block)
        setting = re.search(r"^  : values=(.*)$", block, re.MULTILINE)
        if name and setting:
            values[name[1]] = setting[1]
    return values


def check_routes(capture):
    values = controls()
    for speaker in ("SPK1 ", "SPK2 "):
        for name, expected in (("AMP Enable Switch", "on"), ("DSP1 Preload Switch", "on"),
                               ("DSP1 Firmware", "1"), ("DACPCM Source", "3"), ("Digital PCM Volume", "249")):
            assert values[speaker + name] == expected, (speaker, name, values[speaker + name])
    for name in ("ADC1 Switch", "ADC3 Switch", "TX_AIF1_CAP Mixer DEC2", "TX_AIF1_CAP Mixer DEC5",
                 "MultiMedia3 Mixer TX_CODEC_DMA_TX_3"):
        assert values[name] == ("on" if capture else "off"), (name, values[name])


def wait_for(function, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = function()
        if result:
            return result
        time.sleep(.15)
    raise RuntimeError(label)


def main(mode):
    assert os.getuid() == 1000
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    children = []
    try:
        def start(program, *args):
            output = (runtime / (program + ".log")).open("ab")
            try:
                child = subprocess.Popen([program, *args], stdout=output, stderr=output)
            finally:
                output.close()
            children.append(child)
            return child

        start("pipewire")
        wait_for((runtime / "pipewire-0").is_socket, "PipeWire socket")
        start("wireplumber")
        start("pipewire-pulse")
        wait_for((runtime / "pulse/native").is_socket, "Pulse server socket")
        def card_nodes():
            nodes = graph()
            speakers = [p for p in nodes if p.get("media.class") == "Audio/Sink" and "Speaker" in p["node.name"]]
            mics = [p for p in nodes if p.get("media.class") == "Audio/Source"]
            if len(speakers) == 1 and (mode == "playback" or len(mics) == 1):
                return speakers[0], mics
        sink, mics = wait_for(card_nodes, "Board UCM nodes")
        assert sink["api.alsa.pcm.stream"] == "playback" and sink["api.alsa.path"] == "hw:LenovoY700,0", sink
        assert len(mics) == (mode == "capture")
        if mics:
            mic = mics[0]
            assert "Mic" in mic["node.name"] and mic["api.alsa.pcm.stream"] == "capture"
            assert mic["api.alsa.path"] == "hw:LenovoY700,2", mic
        print(f"MIC_GRAPH mode={mode} server=pipewire-pulse manager=wireplumber speaker_d0p=1 "
              f"source_d2c={len(mics)}", flush=True)
        pcm = runtime / "playback.wav"
        cycle = array("h", [4096, 4096] * 64 + [-4096, -4096] * 64)
        with wave.open(str(pcm), "wb") as output:
            output.setparams((2, 2, 48000, 0, "NONE", ""))
            output.writeframes(cycle.tobytes() * 4500)
        start("pw-play", "--target", sink["node.name"], str(pcm))
        wait_for(lambda: "RUNNING" in Path("/proc/asound/card0/pcm0p/sub0/status").read_text(), "ALSA playback")
        with ThreadPoolExecutor(max_workers=2) as pool:
            monitor_ready, default_ready, release = Event(), Event(), Event()
            monitor = pool.submit(record, (sink["node.name"] + ".monitor").encode(), monitor_ready, release)
            default = pool.submit(record, None, default_ready, release, not mics)
            try:
                assert default_ready.wait(12), "Default input did not answer"
                if mics:
                    sub = Path("/proc/asound/card0/pcm2c/sub0")
                    assert "RUNNING" in (sub / "status").read_text()
                    hw = (sub / "hw_params").read_text()
                    for field in ("format: S16_LE", "channels: 2", "rate: 48000"):
                        assert field in hw, hw
                assert monitor_ready.wait(10), "Monitor did not deliver a full second"
                check_routes(bool(mics))
                time.sleep(.4)
                check_routes(bool(mics))
                print(f"MIC_ROUTES tx3={int(bool(mics))} adc1_adc3={int(bool(mics))} "
                      f"dec2_dec5={int(bool(mics))} protected_speakers=2 raw_gain=249 samples=2", flush=True)
            finally:
                release.set()
            default_samples = default.result(timeout=15)
            if mics:
                assert_tones(default_samples, (1, 2))
                default_signal = "1000,1500"
            elif default_samples is None:
                default_signal = "no_source"
            else:
                assert_tones(default_samples, (0, 0))
                default_signal = "monitor_375,375"
            assert_tones(monitor.result(timeout=15), (0, 0))
        print(f"MIC_AUDIO mode={mode} monitor_hz=375,375 "
              f"default_input={default_signal} frames=48000 channels=2", flush=True)
    except BaseException:
        for name in ("wireplumber", "pipewire", "pipewire-pulse", "pw-play"):
            path = runtime / (name + ".log")
            if path.exists():
                print(path.name, path.read_text(errors="replace")[-2200:], flush=True)
        if (runtime / "pipewire-0").is_socket():
            print("AUDIO_NODES", [(p.get("node.name"), p.get("media.class")) for p in graph()], flush=True)
        raise
    finally:
        for child in reversed(children):
            child.terminate()
        for child in children:
            child.wait(timeout=5)


if __name__ == "__main__":
    signal.alarm(70)
    main(sys.argv[1])
