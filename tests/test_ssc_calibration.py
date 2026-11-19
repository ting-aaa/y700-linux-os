"""Test per-device import using a synthetic read-only ext4 source and fake IMU data."""

import concurrent.futures
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux SSC state and flock')
class CalibrationTests(unittest.TestCase):
    def setUp(self):
        script = Path(__file__).resolve().parents[1]/'scripts/import-ssc-calibration.py'
        spec = importlib.util.spec_from_file_location('ssc_calibration', script)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.seed = self.root/'seed'
        (self.seed/'registry').mkdir(parents=True)
        (self.seed/'sns_reg_version').write_bytes(self.mod.VERSION)
        self.state = self.root/'state'
        self.cal = 'bmi3x0_0_platform.accel.fac_cal.bias'
        self.table = 'sns_gyro_cal_table_s0.g2.21'
        self.config = 'default_sensors.accel_cal'
        for name in (self.cal, self.config):
            (self.seed/'registry'/name).write_bytes(self.group(name, 'default'))
        self.groups = {k: self.mod.group_bytes(k, self.group(k, 'unit')) for k in (self.cal, self.table)}

    @staticmethod
    def group(name, value):
        leaf = {'data': value, 'ver': '0', 'type': 'str'}
        return json.dumps({name: {'field': leaf, 'owner': 'fixture'}}).encode()

    def test_concurrent_publish_preserves_updates_and_retains_defaults(self):
        def install():
            return self.mod.provision(self.seed, self.state, self.groups)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: install(), range(2)))
        self.assertEqual(sum(r.startswith('Imported') for r in results), 1)
        directory = self.state/'registry/registry'
        self.assertEqual(set(p.name for p in directory.iterdir()), {self.cal, self.config, self.table})
        self.assertEqual((directory/self.config).read_bytes(), (self.seed/'registry'/self.config).read_bytes())
        self.assertEqual(list(json.loads((directory/self.cal).read_bytes())[self.cal]['field']),
                         ['type', 'ver', 'data'])
        self.assertEqual((directory/self.table).stat().st_mode & 0o777, 0o600)
        (directory/self.cal).write_bytes(self.group(self.cal, 'learned'))
        install()
        self.assertEqual((directory/self.cal).read_bytes(), self.group(self.cal, 'learned'))
        with self.assertRaisesRegex(ValueError, 'Existing sensor state'):
            self.mod.provision(self.seed, self.state, {self.cal: self.group(self.cal, 'another-unit')})
        self.assertEqual((directory/self.cal).read_bytes(), self.group(self.cal, 'learned'))

    def test_existing_and_symlinked_states_are_rejected(self):
        self.state.mkdir()
        (self.state/'registry').mkdir()
        with self.assertRaisesRegex(ValueError, 'Existing sensor state'):
            self.mod.provision(self.seed, self.state, self.groups)
        (self.state/'registry').rmdir()
        (self.state/'registry').symlink_to(self.seed, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'direct path'):
            self.mod.provision(self.seed, self.state, self.groups)

    def test_mid_write_failure_never_publishes_partial_registry(self):
        with mock.patch.object(self.mod, 'sync_dir', side_effect=OSError('simulated disk error')):
            with self.assertRaises(OSError):
                self.mod.provision(self.seed, self.state, self.groups)
        self.assertFalse((self.state/'registry').exists())
        self.assertEqual(list(self.state.glob('.import-*')), [])
        self.mod.provision(self.seed, self.state, self.groups)

    def test_read_only_ext4_filters_configuration_and_rejects_malformed_inputs(self):
        if not shutil.which('debugfs') or not shutil.which('mke2fs'):
            self.skipTest('Requires e2fsprogs')
        raw_root = self.root/'stock/sensors/registry'
        groups = raw_root/'registry'
        groups.mkdir(parents=True)
        (raw_root/'sns_reg_version').write_bytes(self.mod.VERSION)
        for name in (self.cal, self.table, self.config):
            (groups/name).write_bytes(self.group(name, 'unit'))
        image = self.root/'stock.img'
        with image.open('wb') as f:
            f.truncate(8 * 1024 * 1024)

        def build():
            subprocess.run(['mke2fs', '-qFt', 'ext4', '-d', self.root/'stock', image],
                           check=True, capture_output=True)
        build()
        before = self.mod.sha256(image)
        self.assertEqual(self.mod.factory_groups(image), self.groups)
        self.assertEqual(before, self.mod.sha256(image))
        (groups/self.cal).write_text('{"wrong":{"owner":"bad"}}')
        build()
        with self.assertRaisesRegex(ValueError, 'Invalid SSC group'):
            self.mod.factory_groups(image)
        (raw_root/'sns_reg_version').write_bytes(b'version=8\0')
        build()
        with self.assertRaisesRegex(ValueError, 'version differs'):
            self.mod.factory_groups(image)

    def test_verified_backup_requires_matching_unit_and_all_image_hashes(self):
        root = self.root/'backup'
        (root/'partitions').mkdir(parents=True)
        image = root/'partitions/persist.img'
        with image.open('wb') as stream:
            stream.truncate(self.mod.PARTITION_BYTES)
        digest = self.mod.sha256(image)
        hashes = ('source_sha256_before', 'source_sha256_after', 'staged_sha256', 'pc_sha256')
        entry = dict.fromkeys(hashes, digest)
        entry.update(name='persist', device='/dev/block/sda2', status='verified', source_stable=True,
                     expected_bytes=self.mod.PARTITION_BYTES, written_bytes=self.mod.PARTITION_BYTES)
        manifest = {'device_identity': 'TB320FC\nTB320FC_CN_OPEN.350_fixture', 'schema_version': 2,
                    'serial': 'synthetic-unit', 'results': [entry]}
        manifest_file = root/'manifest.json'
        audit_file = root/'partition_verification.json'
        manifest_file.write_text(json.dumps(manifest))
        audit_file.write_text(json.dumps({'serial': 'another-unit', 'status': 'verified'}))
        with self.assertRaisesRegex(ValueError, 'Backup identity'):
            self.mod.backup_image(root)
        audit_file.write_text(json.dumps({'serial': 'synthetic-unit', 'status': 'verified'}))
        self.assertEqual(self.mod.backup_image(root), image)
        for key in hashes:
            with self.subTest(key=key):
                entry[key] = '0' * 64
                manifest_file.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, 'differs from the backup'):
                    self.mod.backup_image(root)
                entry[key] = digest

    def test_ufs_selection_excludes_carried_media_and_rejects_duplicate_labels(self):
        devices = self.root/'blocks'
        devices.mkdir()
        def add(bus, name):
            block = self.root/bus/name
            block.mkdir(parents=True)
            (block/'partition').write_text('2')
            (block/'uevent').write_text('PARTNAME=persist\n')
            (devices/name).symlink_to(block, target_is_directory=True)
        add('external-usb', 'sdz2')
        with self.assertRaisesRegex(ValueError, 'Expected one internal'):
            self.mod.ufs_persist(devices)
        add('1d84000.ufshc', 'sda2')
        self.assertEqual(self.mod.ufs_persist(devices).name, 'sda2')
        add('1d84000.ufshc', 'sdb2')
        with self.assertRaisesRegex(ValueError, 'Expected one internal'):
            self.mod.ufs_persist(devices)
