#!/usr/bin/python3
"""Stage TB320FC_PRC factory speaker calibration before the protected DSP cores boot."""

import argparse
from contextlib import ExitStack
import ctypes as C
import errno
import grp
import os
from pathlib import Path
import re
import runpy
import stat
import subprocess
import sys
import tempfile
import time

FIELDS = ("CAL_R", "CAL_STATUS", "CAL_CHECKSUM", "CAL_AMBIENT")
BASE_GAIN = 249
CALIBRATED_GAIN = 361
ASOC = Path("/sys/kernel/debug/asoc/Lenovo-Y700")
RUNTIME = Path("/run/y700-speaker-calibration")
FACTORY_TOKEN = re.compile(rb"[-+]?(?:0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)")


def factory_number(raw):
    # The stock HAL uses strtol(base=0) and requires the entire token to parse.
    if not 1 <= len(raw) <= 32 or not FACTORY_TOKEN.fullmatch(raw):
        raise ValueError("Invalid factory integer encoding")
    digits = raw.lstrip(b"+-")
    base = 16 if digits[:2].lower() == b"0x" else (8 if digits.startswith(b"0") else 10)
    return int(raw, base)


def factory_data(read):
    values = []
    for speaker in (1, 2):
        r, f0, ambient = (factory_number(read(f"/audio/spk_{speaker}_{name}"))
                          for name in ("cal_r", "f0", "ambient"))
        # Both channels must pass the stock HAL's separate factory success check.
        # 5.94 < R * 5.8571434021 / 8192 < 7.26, and 477 <= F0 <= 643.
        if not (8308 <= r <= 10154 and 477 <= f0 <= 643):
            raise ValueError(f"SPK{speaker} is outside the TB320FC factory acceptance range")
        if not -(1 << 23) <= ambient < (1 << 23):
            raise ValueError(f"SPK{speaker} ambient does not fit a signed DSP word")
        values.append(tuple((value & 0xffffffff).to_bytes(4, "big") for value in (r, 1, r + 1, ambient)))
    return tuple(values)


def validate_runtime(directory, group):
    info = directory.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != group
            or stat.S_IMODE(info.st_mode) != 0o750):
        raise ValueError("Unexpected speaker calibration directory permissions")


def publish(directory, values, group):
    # /run is local to this boot. No factory data enters the package or image.
    if not directory.exists():
        directory.mkdir(mode=0o700)
        os.chown(directory, 0, group)
        directory.chmod(0o750)
    validate_runtime(directory, group)
    data = b"".join(word for channel in values for word in channel)
    if (directory / "factory").exists():
        if load_runtime(directory, group) != values:
            raise ValueError("An existing factory record differs; refusing replacement")
        return
    with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
        name = Path(output.name)
        try:
            os.fchown(output.fileno(), 0, group)
            os.fchmod(output.fileno(), 0o640)
            output.write(data)
            output.flush()
            try:
                os.link(name, directory / "factory")
            except FileExistsError:
                if load_runtime(directory, group) != values:
                    raise ValueError("A different factory record was published concurrently")
        finally:
            name.unlink(missing_ok=True)


def load_runtime(directory, group):
    validate_runtime(directory, group)
    with os.fdopen(os.open(directory / "factory", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as src:
        info = os.fstat(src.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != group
                or stat.S_IMODE(info.st_mode) != 0o640 or info.st_size != 32):
            raise ValueError("Unexpected speaker calibration file permissions or size")
        data = src.read(33)
    if len(data) != 32:
        raise ValueError("Incomplete speaker calibration file")
    values = tuple(tuple(data[i+j:i+j+4] for j in range(0, 16, 4)) for i in (0, 16))
    for r, status, checksum, ambient in values:
        resistance = int.from_bytes(r, "big")
        if not (8308 <= resistance <= 10154 and int.from_bytes(status, "big") == 1
                and int.from_bytes(checksum, "big") == resistance + 1
                and -(1 << 23) <= int.from_bytes(ambient, "big", signed=True) < 1 << 23):
            raise ValueError("Invalid staged speaker calibration")
    return values


def persist_reader(image):
    def query(op, path):
        result = subprocess.run(["debugfs", "-R", f"{op} {path}", str(image)], capture_output=True,
                                check=True, timeout=5, env={**os.environ, "LC_ALL": "C"})
        if not re.fullmatch(rb"debugfs [^\r\n]+\r?\n", result.stderr):
            raise ValueError("Could not read factory " + path)
        return result.stdout

    def read(path):
        if not re.fullmatch(r"/audio/spk_[12]_(cal_r|f0|ambient)", path):
            raise ValueError("Unexpected factory filename")
        info = query("stat", path)
        size = re.search(rb"^User:.*?\bSize: (\d+)\s*$", info, re.M)
        if b"Type: regular" not in info.splitlines()[0] or not size or not 1 <= int(size[1]) <= 32:
            raise ValueError("Expected a small regular factory file at " + path)
        raw = query("cat", path)
        if len(raw) != int(size[1]):
            raise ValueError("Factory file length changed")
        return raw

    return read


def check_running_dsp():
    for speaker in (1, 2):
        dsp = ASOC / f"cs35l45.6-00{speaker + 29}/DSP1"
        expected = {"booted": "Y", "running": "Y", "hibernating": "N",
                    "fw_id": "0x0004fa00", "fw_version": "0x00002e01",
                    "wmfw_file_name": f"spk{speaker}-cs35l45-dsp1-spk-prot.wmfw",
                    "bin_file_name": f"spk{speaker}-cs35l45-dsp1-spk-prot.bin"}
        for item, value in expected.items():
            if (dsp / item).read_text().strip() != value:
                raise ValueError(f"SPK{speaker} has the wrong DSP state for {item}")


class Alsa:
    """Use a single ALSA control handle so element locks also cover rollback."""
    def __init__(self, stack, readonly=False):
        self.lib = C.CDLL("libasound.so.2")
        ptr, ptrptr = C.c_void_p, C.POINTER(C.c_void_p)
        signatures = {
            "snd_ctl_open": (C.c_int, [ptrptr, C.c_char_p, C.c_int]),
            "snd_ctl_close": (C.c_int, [ptr]),
            "snd_strerror": (C.c_char_p, [C.c_int]),
            "snd_ctl_elem_id_set_interface": (None, [ptr, C.c_int]),
            "snd_ctl_elem_id_set_name": (None, [ptr, C.c_char_p]),
            "snd_ctl_elem_info_set_id": (None, [ptr, ptr]),
            "snd_ctl_elem_value_set_id": (None, [ptr, ptr]),
            "snd_ctl_elem_info": (C.c_int, [ptr, ptr]),
            "snd_ctl_elem_read": (C.c_int, [ptr, ptr]),
            "snd_ctl_elem_write": (C.c_int, [ptr, ptr]),
            "snd_ctl_elem_lock": (C.c_int, [ptr, ptr]),
            "snd_ctl_elem_value_get_boolean": (C.c_int, [ptr, C.c_uint]),
            "snd_ctl_elem_value_set_boolean": (None, [ptr, C.c_uint, C.c_long]),
            "snd_ctl_elem_value_get_enumerated": (C.c_uint, [ptr, C.c_uint]),
            "snd_ctl_elem_value_get_integer": (C.c_long, [ptr, C.c_uint]),
            "snd_ctl_elem_value_set_integer": (None, [ptr, C.c_uint, C.c_long]),
            "snd_ctl_convert_to_dB": (C.c_int, [ptr, ptr, C.c_long, C.POINTER(C.c_long)]),
            "snd_ctl_elem_info_set_item": (None, [ptr, C.c_uint]),
            "snd_ctl_elem_info_get_item_name": (C.c_char_p, [ptr]),
            "snd_ctl_elem_value_get_byte": (C.c_ubyte, [ptr, C.c_uint]),
            "snd_ctl_elem_value_set_byte": (None, [ptr, C.c_uint, C.c_ubyte]),
        }
        for op in ("get_type", "get_count", "is_readable", "is_writable"):
            signatures["snd_ctl_elem_info_" + op] = (C.c_int, [ptr])
        for kind in ("id", "info", "value"):
            signatures["snd_ctl_elem_" + kind + "_malloc"] = (C.c_int, [ptrptr])
            signatures["snd_ctl_elem_" + kind + "_free"] = (None, [ptr])
        for name, (restype, argtypes) in signatures.items():
            func = getattr(self.lib, name)
            func.argtypes, func.restype = argtypes, restype
        self.handle = ptr()
        self.check(self.lib.snd_ctl_open(C.byref(self.handle), b"hw:LenovoY700", 4 if readonly else 0))
        stack.callback(self.lib.snd_ctl_close, self.handle)
        self.objects = {}
        for kind in ("id", "info", "value"):
            obj = ptr()
            self.check(getattr(self.lib, "snd_ctl_elem_" + kind + "_malloc")(C.byref(obj)))
            stack.callback(getattr(self.lib, "snd_ctl_elem_" + kind + "_free"), obj)
            self.objects[kind] = obj

    def check(self, result):
        if result < 0:
            raise OSError(-result, self.lib.snd_strerror(result).decode())

    def select(self, name):
        elem = self.objects["id"]
        self.lib.snd_ctl_elem_id_set_interface(elem, 2)  # SND_CTL_ELEM_IFACE_MIXER
        self.lib.snd_ctl_elem_id_set_name(elem, name.encode("ascii"))
        return elem

    def lock(self, name, kind="bytes"):
        elem = self.select(name)
        self.check(self.lib.snd_ctl_elem_lock(self.handle, elem))
        info = self.objects["info"]
        self.lib.snd_ctl_elem_info_set_id(info, elem)
        self.check(self.lib.snd_ctl_elem_info(self.handle, info))
        shape = self.lib.snd_ctl_elem_info_get_type(info), self.lib.snd_ctl_elem_info_get_count(info)
        expected = {"switch": (1, 1), "gain": (2, 1), "firmware": (3, 1), "bytes": (4, 4)}[kind]
        rw = self.lib.snd_ctl_elem_info_is_readable(info) and self.lib.snd_ctl_elem_info_is_writable(info)
        if shape != expected or not rw:
            raise ValueError("Unexpected ALSA control layout: " + name)
        if kind == "gain":
            for raw, expected_db in ((BASE_GAIN, -4000), (CALIBRATED_GAIN, -1200)):
                measured = C.c_long()
                self.check(self.lib.snd_ctl_convert_to_dB(self.handle, elem, raw, C.byref(measured)))
                if measured.value != expected_db:
                    raise ValueError("Unexpected CS35L45 digital gain scale")

    def read(self, name, kind="bytes"):
        obj = self.objects["value"]
        self.lib.snd_ctl_elem_value_set_id(obj, self.select(name))
        self.check(self.lib.snd_ctl_elem_read(self.handle, obj))
        if kind == "switch":
            return bool(self.lib.snd_ctl_elem_value_get_boolean(obj, 0))
        if kind == "gain":
            return self.lib.snd_ctl_elem_value_get_integer(obj, 0)
        if kind == "firmware":
            index = self.lib.snd_ctl_elem_value_get_enumerated(obj, 0)
            info = self.objects["info"]
            self.lib.snd_ctl_elem_info_set_id(info, self.select(name))
            self.lib.snd_ctl_elem_info_set_item(info, index)
            self.check(self.lib.snd_ctl_elem_info(self.handle, info))
            return self.lib.snd_ctl_elem_info_get_item_name(info).decode("ascii")
        return bytes(self.lib.snd_ctl_elem_value_get_byte(obj, i) for i in range(4))

    def write(self, name, data):
        obj = self.objects["value"]
        self.lib.snd_ctl_elem_value_set_id(obj, self.select(name))
        for i, value in enumerate(data):
            self.lib.snd_ctl_elem_value_set_byte(obj, i, value)
        self.check(self.lib.snd_ctl_elem_write(self.handle, obj))

    def has(self, name):
        info = self.objects["info"]
        self.lib.snd_ctl_elem_info_set_id(info, self.select(name))
        result = self.lib.snd_ctl_elem_info(self.handle, info)
        if result == -errno.ENOENT:
            return False
        self.check(result)
        return True

    def write_gain(self, name, raw):
        if name not in ("SPK1 Digital PCM Volume", "SPK2 Digital PCM Volume") or raw not in (BASE_GAIN, CALIBRATED_GAIN):
            raise ValueError("Unexpected digital gain request")
        obj = self.objects["value"]
        self.lib.snd_ctl_elem_value_set_id(obj, self.select(name))
        self.lib.snd_ctl_elem_value_set_integer(obj, 0, raw)
        self.check(self.lib.snd_ctl_elem_write(self.handle, obj))

    def preload(self, name, enable):
        if name not in ("SPK1 DSP1 Preload Switch", "SPK2 DSP1 Preload Switch"):
            raise ValueError("Expected a Protection preload switch")
        obj = self.objects["value"]
        self.lib.snd_ctl_elem_value_set_id(obj, self.select(name))
        self.lib.snd_ctl_elem_value_set_boolean(obj, 0, int(enable))
        self.check(self.lib.snd_ctl_elem_write(self.handle, obj))


def stage(alsa, values):
    switches = [f"SPK{n} {switch}" for n in (1, 2) for switch in ("AMP Enable Switch", "DSP1 Preload Switch")]
    firmware = [f"SPK{n} DSP1 Firmware" for n in (1, 2)]
    settings = {f"SPK{n} DSP1 Protection cd {field}": word
                for n, channel in enumerate(values, 1) for field, word in zip(FIELDS, channel, strict=True)}
    for name in switches:
        alsa.lock(name, "switch")
    if any(alsa.read(name, "switch") for name in switches):
        raise ValueError("Both AMP Enable and both DSP1 Preload switches must already be off")
    for name in firmware:
        alsa.lock(name, "firmware")
    if any(alsa.read(name, "firmware") != "Protection" for name in firmware):
        raise ValueError("Both speaker DSPs must have Protection selected")
    gains = [f"SPK{n} Digital PCM Volume" for n in (1, 2)]
    for name in gains:
        alsa.lock(name, "gain")
    original_gains = {name: alsa.read(name, "gain") for name in gains}
    if any(gain not in (BASE_GAIN, CALIBRATED_GAIN) for gain in original_gains.values()):
        raise ValueError("Expected the qualified UCM or calibrated digital gain")
    if not all(alsa.has(name) for name in settings):
        # Controls first appear after firmware discovery and survive a DSP power-down.
        # AMP Enable stays locked off. Never toggle a working core on later UCM enables.
        attempted = []
        try:
            for n in (1, 2):
                name = f"SPK{n} DSP1 Preload Switch"
                attempted.append(name)
                alsa.preload(name, True)
            deadline = time.monotonic() + 2
            while not all(alsa.has(name) for name in settings):
                if time.monotonic() >= deadline:
                    raise ValueError("Protection controls did not appear")
                time.sleep(.03)
        finally:
            failures = []
            for name in reversed(attempted):
                try:
                    alsa.preload(name, False)
                except OSError:
                    failures.append(name)
            if failures:
                raise RuntimeError("Could not close temporary Protection preload; keep AMP switches off")
        if any(alsa.read(name, "switch") for name in switches):
            raise ValueError("Protection preloads did not close")
    for name in settings:
        alsa.lock(name)
    previous = {name: alsa.read(name) for name in settings}
    if previous == settings and all(raw == CALIBRATED_GAIN for raw in original_gains.values()):
        return False
    for n in (1, 2):
        keys = [f"SPK{n} DSP1 Protection cd {field}" for field in FIELDS]
        # A terminated earlier run may have staged only a prefix of the values.
        # An unrelated nonzero resistance or checksum must never be replaced.
        if any(previous[k] not in (bytes(4), settings[k]) for k in keys[:3]):
            raise ValueError(f"SPK{n} already has a different calibration")
    attempted = []
    attempted_gains = []
    try:
        for name, word in settings.items():
            if previous[name] == word:
                continue
            attempted.append(name)
            alsa.write(name, word)
        if any(alsa.read(name) != word for name, word in settings.items()):
            raise ValueError("Factory calibration readback did not match")
        for name, old in original_gains.items():
            if old != CALIBRATED_GAIN:
                attempted_gains.append(name)
                alsa.write_gain(name, CALIBRATED_GAIN)
        if any(alsa.read(name, "gain") != CALIBRATED_GAIN for name in gains):
            raise ValueError("Calibrated digital gain readback did not match")
    except BaseException as failure:
        broken = False
        for name in reversed(attempted_gains):
            try:
                alsa.write_gain(name, original_gains[name])
                if alsa.read(name, "gain") != original_gains[name]:
                    broken = True
            except (ValueError, OSError):
                broken = True
        for name in reversed(attempted):
            try:
                alsa.write(name, previous[name])
                if alsa.read(name) != previous[name]:
                    broken = True
            except (ValueError, OSError):
                broken = True
        if broken:
            raise RuntimeError("Calibration rollback incomplete; keep the amplifier switches off") from failure
        raise
    return True


def verify(alsa, values, dsp_ready):
    dsp_ready()
    for n, channel in enumerate(values, 1):
        prefix = f"SPK{n} DSP1 Protection cd "
        if any(alsa.read(prefix + field) != word for field, word in zip(FIELDS, channel, strict=True)):
            raise ValueError(f"SPK{n} calibration controls differ from factory data")
        if alsa.read(prefix + "CAL_R_SELECTED") != channel[0]:
            raise ValueError(f"SPK{n} firmware did not select this speaker's factory resistance")
        if alsa.read(prefix + "CAL_SET_STATUS") != b"\0\0\0\x02":
            raise ValueError(f"SPK{n} did not report the applied factory calibration state")
        if alsa.read(prefix + "CSPL_ERRORNO") != bytes(4):
            raise ValueError(f"SPK{n} protection reported an error")
    dsp_ready()


def playback_ready():
    if "state: RUNNING" not in Path("/proc/asound/LenovoY700/pcm0p/sub0/status").read_text().splitlines():
        return False
    for n in (1, 2):
        amp = ASOC / f"cs35l45.6-00{n+29}/dapm/SPK{n} AMP"
        if not amp.read_text().startswith(f"SPK{n} AMP: On "):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("check-backup").add_argument("backup", type=Path, help="Verified TB320FC PRC Android backup root")
    sub.add_parser("check-live", help="Validate the tablet's factory partition without opening ALSA")
    sub.add_parser("prepare-live", help="As root, validate this tablet's factory partition and publish to /run")
    sub.add_parser("stage", help="As the audio process, stage prepared values during protected speaker enable")
    sub.add_parser("verify-live", help="Confirm each running Protection core selected its own factory resistance")
    args = parser.parse_args()
    group = grp.getgrnam("audio").gr_gid
    if args.action in ("stage", "verify-live"):
        try:
            values = load_runtime(RUNTIME, group)
        except FileNotFoundError:
            if args.action == "verify-live":
                raise ValueError("Factory speaker calibration has not been prepared")
            print("No prepared factory record; continuing with the board Protection tuning")
            return
    else:
        helper = Path(__file__).resolve().with_name("import-ssc-calibration.py")
        if not helper.is_file():
            helper = Path("/usr/libexec/y700-ssc/import-calibration")
        board = runpy.run_path(str(helper))
        image = board["backup_image"](args.backup) if args.action == "check-backup" else board["live_image"]()
        values = factory_data(persist_reader(image))
    if args.action == "stage":
        with ExitStack() as stack:
            changed = stage(Alsa(stack), values)
        print("Both factory records staged for the next Protection boot" if changed else "Both Protection caches already match")
    elif args.action == "verify-live":
        if not playback_ready():
            print("Pending normal speaker playback")
            sys.exit(3)
        with ExitStack() as stack:
            verify(Alsa(stack, readonly=True), values, check_running_dsp)
        if not playback_ready():
            print("Playback ended during verification")
            sys.exit(3)
        print("Both Protection DSPs selected their own factory resistance and report zero CSPL errors")
    elif args.action == "prepare-live":
        publish(RUNTIME, values, group)
        print("Factory speaker calibration prepared for this boot")
    else:
        print("Both factory speaker records passed board identity, file format and factory range checks")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
