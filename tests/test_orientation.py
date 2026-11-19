import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('orientation', Path(__file__).resolve().parents[1]/'src/sensors/y700-auto-rotate.py')
orientation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(orientation)


class OrientationTests(unittest.TestCase):
    def test_monitor_sensor_initial_pose_and_restart(self):
        policy = orientation.OrientationPolicy(0.8)
        for message in ('=== No accelerometer', '--- iio-sensor-proxy vanished, waiting for it to appear'):
            orientation.monitor_event(policy, '=== Has accelerometer (orientation: left-up, tilt: vertical)', 0)
            self.assertEqual(policy.due(1), 'left')
            orientation.monitor_event(policy, message, 1.1)
            self.assertIsNone(policy.due(2))
        orientation.monitor_event(policy, '    Accelerometer orientation changed: bottom-up', 3)
        self.assertEqual(policy.due(4), 'inverted')

    def test_all_directions_need_stable_pose_and_do_not_repeat(self):
        policy = orientation.OrientationPolicy(0.8)
        for name, expected in orientation.ROTATIONS.items():
            policy.observe(name, 10)
            self.assertIsNone(policy.due(10.5))
            self.assertEqual(policy.due(11), expected)
            policy.complete(expected, True, 11)
            self.assertIsNone(policy.due(12))

    def test_jitter_unknown_and_lock_cancel_pending_rotation(self):
        policy = orientation.OrientationPolicy(0.8)
        policy.observe('left-up', 0)
        policy.observe('right-up', 0.5)
        self.assertIsNone(policy.due(1))
        policy.observe('undefined', 1)
        self.assertIsNone(policy.due(5))
        policy.observe('normal', 6)
        self.assertIsNone(policy.due(7, locked=True))
        self.assertIsNone(policy.due(8))
        policy.observe('right-up', 9)
        self.assertEqual(policy.due(10), 'right')

    def test_failed_mapping_retries_with_delay(self):
        policy = orientation.OrientationPolicy(0.8)
        policy.observe('left-up', 0)
        policy.complete(policy.due(1), False, 1)
        self.assertIsNone(policy.due(1.1))
        self.assertEqual(policy.due(2), 'left')


if __name__ == '__main__':
    unittest.main()
