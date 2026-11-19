"""Check the optional camera layer can vary only its reviewed runtime archive."""

import copy
import json
from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from camera_layer import DEFAULT_LOCK, RUNTIME, load_camera_lock, validate_camera_lock


class CameraLayerTests(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads(DEFAULT_LOCK.read_text())
        self.runtime = next(item for item in self.lock['packages'] if item['package'] == RUNTIME)

    def test_development_lock(self):
        self.assertEqual(len(load_camera_lock(DEFAULT_LOCK)), 7)

    def test_reviewed_runtime_rebuild_changes_only_hash_and_size(self):
        self.runtime.update(size=42, sha256='a' * 64)
        actual = validate_camera_lock(self.lock)
        self.assertIn(self.runtime, actual)

    def test_debian_archive_cannot_change(self):
        self.lock['packages'][0]['sha256'] = 'b' * 64
        with self.assertRaisesRegex(ValueError, 'authenticated'):
            validate_camera_lock(self.lock)

    def test_runtime_tuple_cannot_change(self):
        for key, value in (('version', '1.0.0'), ('architecture', 'amd64')):
            with self.subTest(key=key):
                lock = copy.deepcopy(self.lock)
                item = next(entry for entry in lock['packages'] if entry['package'] == RUNTIME)
                item[key] = value
                with self.assertRaisesRegex(ValueError, 'pinned ARM64 version'):
                    validate_camera_lock(lock)

    def test_package_membership_is_exact(self):
        self.lock['packages'][0] = copy.deepcopy(self.runtime)
        with self.assertRaisesRegex(ValueError, 'seven distinct packages'):
            validate_camera_lock(self.lock)


if __name__ == '__main__':
    unittest.main()
