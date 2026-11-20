"""Verify the physical probe's two wire protocols and recovery after a failed read."""
from contextlib import nullcontext, redirect_stdout
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


@unittest.skipUnless(sys.platform.startswith("linux"), "the probe uses Linux i2c-dev")
class FocusProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).with_name("camera-focus-probe.py")
        spec = importlib.util.spec_from_file_location("focus_probe", path)
        cls.probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.probe)

    def test_fixed_chip_identity_read(self):
        p = self.probe
        def adapter(fd, command, request):
            self.assertEqual((fd, command, request.command, request.read_write, request.size),
                             (13, p.I2C_SMBUS, 0, 1, 2))
            request.data.contents.byte = 0xe9
            return 0
        with patch.object(p, "open_bus", return_value=nullcontext(13)) as opened, \
                patch.object(p.fcntl, "ioctl", side_effect=adapter), redirect_stdout(io.StringIO()):
            p.read_chip_id(Path("i2c-0"))
        opened.assert_called_once_with(Path("i2c-0"), 0x0c)

    def test_minimal_calibration_read(self):
        p = self.probe
        payload = bytes(range(11))
        def adapter(fd, command, request):
            self.assertEqual((fd, command, request.count), (17, p.I2C_RDWR, 2))
            first, second = request.messages[:2]
            self.assertEqual((first.address, first.flags, bytes(first.data[:first.length])),
                             (0x58, 0, b"\x00\x27"))
            self.assertEqual((second.address, second.flags, second.length), (0x58, 1, 11))
            for i, value in enumerate(payload):
                second.data[i] = value
            return 2
        decode = Mock(return_value={"factory_infinity_dac": 70, "factory_macro_dac": 400})
        with tempfile.TemporaryDirectory() as tmp, patch.object(p, "SYS", Path(tmp)), \
                patch.object(p, "open_bus", return_value=nullcontext(17)), \
                patch.object(p.fcntl, "ioctl", side_effect=adapter), redirect_stdout(io.StringIO()):
            p.verify_calibration(Path("i2c-0"), {}, decode)
        decode.assert_called_once_with(payload, {})

    def test_failed_powered_read_restores_auto(self):
        p = self.probe
        with tempfile.TemporaryDirectory() as tmp:
            sensor = Path(tmp) / "sensor"
            (sensor / "power").mkdir(parents=True)
            (sensor / "driver").symlink_to(Path(tmp) / "asphalt-sensors")
            control = sensor / "power/control"
            control.write_text("auto")
            (sensor / "power/runtime_status").write_text("active")
            with patch.object(p.subprocess, "run") as run, redirect_stdout(io.StringIO()):
                with self.assertRaises(OSError), p.main_sensor_power(sensor, True):
                    self.assertEqual(control.read_text().strip(), "on")
                    raise OSError("simulated NACK")
            self.assertEqual(control.read_text().strip(), "auto")
            arm, disarm = [call.args[0] for call in run.call_args_list]
            self.assertEqual(arm[0], "systemd-run")
            self.assertEqual(arm[-1], str(control))
            timer = next(arg.removeprefix("--unit=") for arg in arm if arg.startswith("--unit="))
            self.assertEqual(disarm, ["systemctl", "stop", timer + ".timer"])


if __name__ == "__main__":
    unittest.main()
