"""Exercise peer selection and exclusive capture with temporary files and pipes only."""
from contextlib import ExitStack
import fcntl
import os
from pathlib import Path
import runpy
import struct
import tempfile
import time
import unittest
from unittest.mock import patch

api = runpy.run_path(str(Path(__file__).with_name("capture-input.py")))
HOST = "112233445566"
IDENTITY = "AABBCCDDEEFF"


class CaptureTests(unittest.TestCase):
    def test_fresh_private_peer(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            directory = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            stack.callback(os.close, directory)
            path = Path(tmp, "peer-address")
            path.write_text("AA:BB:CC:DD:EE:FF\n")
            path.chmod(0o600)
            self.assertIsNone(api["alternate"](directory, time.time_ns() + 1))
            if os.getuid() == 0:
                self.assertEqual(api["alternate"](directory, 0), IDENTITY)
            path.chmod(0o644)
            self.assertIsNone(api["alternate"](directory, 0))

    def test_candidate(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            node = Path(tmp, "event40")
            (node / "device/id").mkdir(parents=True)
            (node / "device/id/bustype").write_text("0005")
            (node / "device/uniq").write_text("11:22:33:44:55:66")
            with patch("os.open", side_effect=AssertionError("foreign peer opened")):
                self.assertIsNone(api["candidate"](node, {IDENTITY}, stack))
            fd = os.open(os.devnull, os.O_RDONLY)
            dev = os.fstat(fd).st_rdev
            (node / "dev").write_text(f"{os.major(dev)}:{os.minor(dev)}")
            # A harmless character fd stands in for an event node. The ioctl
            # answers on that specific open fd must agree with the sysfs data.
            replies = {2: struct.pack("@4H", 5, 0, 0, 0), 8: b"11:22:33:44:55:66\0",
                       0x21: (1 << 185).to_bytes(96, "little"), 0x22: bytes(8)}
            def ioctl_answer(actual, request, buf):
                self.assertEqual(actual, fd)
                reply = replies[request & 255]
                buf[:len(reply)] = reply
            with patch("os.open", return_value=fd), patch.object(fcntl, "ioctl", ioctl_answer):
                self.assertEqual(api["candidate"](node, {HOST}, stack), (HOST, fd, True, False))

    def test_pair_is_unambiguous_and_same_peer(self):
        key = (HOST, 10, True, False)
        mouse = (HOST, 11, False, True)
        pair = api["unique_pair"]
        self.assertEqual(pair([key, mouse]), (10, 11))
        self.assertEqual(pair([(HOST, 9, True, True)]), (9, 9))
        self.assertIsNone(pair([key, (IDENTITY, 11, False, True)]))
        self.assertIsNone(pair([key, mouse, (HOST, 12, True, False)]))

    @unittest.skipUnless(os.geteuid() == 0, "supervisor runs as root")
    def test_unconfirmed_run_never_scans_and_leaves_directory_unlocked(self):
        with tempfile.TemporaryDirectory(prefix="y700-offline-", dir="/run") as tmp:
            runtime = Path(tmp)
            def check_directory_available(_):
                with ExitStack() as stack:
                    directory = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
                    stack.callback(os.close, directory)
                    fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    lock = os.open(runtime / "capture-lock", os.O_RDONLY)
                    stack.callback(os.close, lock)
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                raise InterruptedError
            with patch.object(Path, "glob", side_effect=AssertionError("premature scan")), \
                    patch.object(time, "sleep", check_directory_available):
                with self.assertRaises(InterruptedError):
                    api["capture"](runtime, HOST, 1)
            self.assertFalse((runtime / "input-ready").exists())
            self.assertFalse((runtime / "input-done").exists())

    def test_exclusive_capture(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            directory = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            stack.callback(os.close, directory)
            key, write_key = os.pipe2(os.O_NONBLOCK)
            mouse, write_mouse = os.pipe2(os.O_NONBLOCK)
            for fd in (key, write_key, mouse, write_mouse):
                stack.callback(os.close, fd)
            grabs = []
            def grab(fd, request, value):
                self.assertEqual((request, value), (api["EVIOCGRAB"], 1))
                self.assertFalse(Path(tmp, "input-ready").exists())
                grabs.append(fd)
            def emit(line, **kwargs):
                if line == "TABLET_INPUT_READY":
                    self.assertCountEqual(grabs, (key, mouse))
                    self.assertEqual(Path(tmp, "input-ready").read_text(), "1\n")
                    self.assertFalse(Path(tmp, "input-done").exists())
                    pack = api["EVENT"].pack
                    os.write(write_key, pack(0, 0, 1, 185, 1) + pack(0, 0, 1, 185, 0))
                    os.write(write_mouse, pack(0, 0, 2, 0, 1) + pack(0, 0, 2, 1, -1)
                             + pack(0, 0, 0, 0, 0))
                else:
                    self.assertEqual(line, "F15_PRESS_RELEASE_AND_RELATIVE_XY_VERIFIED")
            with patch.object(fcntl, "ioctl", grab), patch("builtins.print", emit):
                api["read_events"]((key, mouse), directory, time.monotonic() + 2)
            self.assertFalse(Path(tmp, "input-ready").exists())
            self.assertEqual(Path(tmp, "input-done").read_text(), "1\n")

    def test_split_mouse_frame_or_release_without_press_does_not_complete(self):
        r = api["Reports"](8, 9)
        for event in [(8, 1, 185, 0), (9, 2, 0, 1), (9, 0, 0, 0), (9, 2, 1, -1),
                      (9, 0, 0, 0), (8, 1, 185, 1), (8, 1, 185, 0)]:
            r.event(*event)
        self.assertFalse(r.done())
        with self.assertRaises(RuntimeError):
            r.event(9, 0, 3, 0)

    def test_failed_second_grab_never_arms(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            directory = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            stack.callback(os.close, directory)
            with patch.object(fcntl, "ioctl", side_effect=[0, BlockingIOError]), \
                    self.assertRaises(BlockingIOError):
                api["read_events"]((50, 51), directory, time.monotonic() + 1)
            self.assertEqual(os.listdir(directory), [])


if __name__ == "__main__":
    unittest.main()
