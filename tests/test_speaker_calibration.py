import grp
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest

UTIL = runpy.run_path(str(Path(__file__).resolve().parents[1]/"scripts/speaker-calibration.py"))
FIELDS = UTIL["FIELDS"]


def sample(path):
    n = int(path[len("/audio/spk_")])
    return {"cal_r": (b"0x2400", b"9501")[n-1], "f0": b"560", "ambient": b"25"}[path.split("_", 2)[2]]


class Card:
    def __init__(self):
        self.values = {f"SPK{n} DSP1 Protection cd {field}": bytes(4) for n in (1, 2) for field in FIELDS}
        self.locks = []
        self.writes = []
        self.gain_writes = []
        self.preloads = []
        self.registered = True
        self.fail = None
        for n in (1, 2):
            self.values[f"SPK{n} AMP Enable Switch"] = False
            self.values[f"SPK{n} DSP1 Preload Switch"] = False
            self.values[f"SPK{n} DSP1 Firmware"] = "Protection"
            self.values[f"SPK{n} Digital PCM Volume"] = 249

    def lock(self, name, kind="bytes"):
        if name not in self.values:
            raise OSError("unknown control")
        self.locks.append(name)

    def has(self, name):
        return self.registered and name in self.values

    def preload(self, name, enabled):
        assert name in self.locks and "Preload" in name
        assert all(self.values[f"SPK{n} AMP Enable Switch"] is False for n in (1, 2))
        self.values[name] = enabled
        self.preloads.append((name, enabled))
        if all(self.values[f"SPK{n} DSP1 Preload Switch"] for n in (1, 2)):
            self.registered = True

    def read(self, name, kind="bytes"):
        return self.values[name]

    def write(self, name, value):
        assert len(value) == 4 and name in self.locks and name.rsplit(" ", 1)[-1] in FIELDS
        assert all(not self.values[f"SPK{n} DSP1 Preload Switch"] for n in (1, 2))
        self.values[name] = value
        self.writes.append(name)
        if self.fail == name:
            self.fail = None
            raise OSError("simulated post-write error")

    def write_gain(self, name, raw):
        assert name in self.locks and raw in (249, 361)
        assert all(not self.values[f"SPK{n} AMP Enable Switch"] for n in (1, 2))
        self.values[name] = raw
        self.gain_writes.append((name, raw))
        if self.fail == name:
            self.fail = None
            raise OSError("simulated post-write gain failure")


class SpeakerTests(unittest.TestCase):
    def setUp(self):
        self.values = UTIL["factory_data"](sample)
        self.card = Card()

    def test_vendor_format_and_range(self):
        self.assertEqual(self.values[0], tuple(i.to_bytes(4, "big") for i in (9216, 1, 9217, 25)))
        self.assertEqual(self.values[1][0], (9501).to_bytes(4, "big"))
        self.assertEqual(UTIL["factory_number"](b"017"), 15)
        for field, bad in [("cal_r", b"8307"), ("cal_r", b"10155"), ("f0", b"476"), ("f0", b"644"),
                           ("cal_r", b"9000\n"), ("cal_r", b"9_000"), ("ambient", b"-8388609")]:
            with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                UTIL["factory_data"](lambda p: bad if p.endswith("_"+field) else sample(p))
        for r in (8308, 10154):
            for f in (477, 643):
                UTIL["factory_data"](lambda p: str(r if p.endswith("cal_r") else f if p.endswith("f0") else 25).encode())

    @unittest.skipUnless(shutil.which("mkfs.ext4") and shutil.which("debugfs"), "requires e2fsprogs")
    def test_actual_ext4_factory_reader(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            audio = base/"tree/audio"
            audio.mkdir(parents=True)
            for n in (1, 2):
                for field in ("cal_r", "f0", "ambient"):
                    name = f"spk_{n}_{field}"
                    (audio/name).write_bytes(sample("/audio/"+name))
            (audio/"alias").symlink_to("spk_1_f0")
            image = base/"persist.ext4"
            with image.open("wb") as f:
                f.truncate(8*1024*1024)
            def format_image():
                subprocess.run(["mkfs.ext4", "-qF", "-d", str(base/"tree"), str(image)], check=True)
            format_image()
            reader = UTIL["persist_reader"](image)
            self.assertEqual(UTIL["factory_data"](reader), self.values)
            with self.assertRaises(ValueError):
                reader("/audio/../audio/alias")
            (audio/"spk_1_f0").unlink()
            (audio/"spk_1_f0").symlink_to("spk_2_f0")
            format_image()
            with self.assertRaises(ValueError):
                UTIL["factory_data"](reader)

    @unittest.skipUnless(os.geteuid() == 0, "requires ownership checks on a Linux filesystem")
    def test_private_runtime_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)/"runtime"
            gid = grp.getgrnam("audio").gr_gid
            UTIL["publish"](directory, self.values, gid)
            UTIL["publish"](directory, self.values, gid)
            self.assertEqual(UTIL["load_runtime"](directory, gid), self.values)
            other = UTIL["factory_data"](lambda p: b"9300" if p.endswith("cal_r") else sample(p))
            with self.assertRaises(ValueError):
                UTIL["publish"](directory, other, gid)
            record = directory/"factory"
            record.chmod(0o660)
            with self.assertRaises(ValueError):
                UTIL["load_runtime"](directory, gid)
            record.unlink()
            record.symlink_to("/dev/null")
            with self.assertRaises(OSError):
                UTIL["load_runtime"](directory, gid)

    def test_cold_registration_and_repeated_stage(self):
        self.card.registered = False
        self.assertTrue(UTIL["stage"](self.card, self.values))
        self.assertEqual(len(self.card.preloads), 4)
        self.assertEqual(self.card.writes, [f"SPK{n} DSP1 Protection cd {field}" for n in (1, 2) for field in FIELDS])
        self.assertFalse(UTIL["stage"](self.card, self.values))
        self.assertEqual(len(self.card.writes), 8)
        self.assertEqual(len(self.card.preloads), 4)
        self.assertEqual(self.card.gain_writes, [(f"SPK{n} Digital PCM Volume", 361) for n in (1, 2)])

    def test_safety_checks_precede_writes(self):
        for name, value in [("SPK1 AMP Enable Switch", True), ("SPK2 DSP1 Preload Switch", True),
                            ("SPK1 DSP1 Firmware", "Calibration"), ("SPK1 Digital PCM Volume", 455),
                            ("SPK2 DSP1 Protection cd CAL_CHECKSUM", b"\x01\x02\x03\x04")]:
            card = Card()
            card.values[name] = value
            with self.subTest(name=name), self.assertRaises(ValueError):
                UTIL["stage"](card, self.values)
            self.assertFalse(card.writes)
            self.assertFalse(card.preloads)
            self.assertFalse(card.gain_writes)

    def test_partial_write_rolls_back_both_channels(self):
        initial = self.card.values.copy()
        self.card.fail = "SPK2 DSP1 Protection cd CAL_STATUS"
        with self.assertRaises(OSError):
            UTIL["stage"](self.card, self.values)
        self.assertEqual(self.card.values, initial)

    def test_gain_failure_restores_both_gains_and_calibrations(self):
        initial = self.card.values.copy()
        self.card.fail = "SPK2 Digital PCM Volume"
        with self.assertRaises(OSError):
            UTIL["stage"](self.card, self.values)
        self.assertEqual(self.card.values, initial)
        self.assertEqual(self.card.gain_writes[-2:], [("SPK2 Digital PCM Volume", 249), ("SPK1 Digital PCM Volume", 249)])

    def test_existing_calibration_with_base_gain_still_sets_verified_gain(self):
        UTIL["stage"](self.card, self.values)
        self.card.writes.clear()
        self.card.gain_writes.clear()
        for n in (1, 2):
            self.card.values[f"SPK{n} Digital PCM Volume"] = 249
        self.assertTrue(UTIL["stage"](self.card, self.values))
        self.assertFalse(self.card.writes)
        self.assertEqual(len(self.card.gain_writes), 2)

    def test_interrupted_prefix_can_be_completed_without_changing_other_coefficients(self):
        self.card.values["SPK1 DSP1 Protection cd CAL_R"] = self.values[0][0]
        self.assertTrue(UTIL["stage"](self.card, self.values))
        self.assertFalse(UTIL["stage"](self.card, self.values))

    def test_effective_state_must_be_observed(self):
        UTIL["stage"](self.card, self.values)
        for n, channel in enumerate(self.values, 1):
            group = f"SPK{n} DSP1 Protection cd "
            self.card.values[group+"CAL_R_SELECTED"] = channel[0]
            self.card.values[group+"CSPL_ERRORNO"] = bytes(4)
            self.card.values[group+"CAL_SET_STATUS"] = (2).to_bytes(4, "big")
        UTIL["verify"](self.card, self.values, lambda: None)
        for key, value in (("CAL_R_SELECTED", (7972).to_bytes(4, "big")), ("CAL_SET_STATUS", bytes(4)),
                           ("CSPL_ERRORNO", (1).to_bytes(4, "big"))):
            name = "SPK2 DSP1 Protection cd " + key
            saved = self.card.values[name]
            self.card.values[name] = value
            with self.assertRaises(ValueError):
                UTIL["verify"](self.card, self.values, lambda: None)
            self.card.values[name] = saved


if __name__ == "__main__":
    unittest.main()
