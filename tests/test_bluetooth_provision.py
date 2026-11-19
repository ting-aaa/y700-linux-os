import io
import os
from pathlib import Path
import runpy
import tempfile
import unittest


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'scripts/prepare-bluetooth-identity.py'))
ADDRESS = '02:00:00:00:01:AB'


class BluetoothProvisionTests(unittest.TestCase):
    def test_extracts_local_identity_without_copying_peers(self):
        rows = io.StringIO('[paired-device]\nAddress = FA:00:00:00:00:01\n'
                           f'[Adapter]\nAddress = {ADDRESS.lower()}\n[other]\nAddress = broken\n')
        self.assertEqual(MODULE['local_address'](rows), ADDRESS)
        MODULE['cross_check']([f'[persist.vendor.service.bdroid.bdaddr]: [{ADDRESS}]'], ADDRESS)

    def test_rejects_ambiguous_or_disagreeing_stock_state(self):
        for rows in ('[Adapter]\nAddress=00:00:00:00:00:00\n', '[peer]\nAddress=' + ADDRESS,
                     f'[Adapter]\nAddress={ADDRESS}\nAddress={ADDRESS}\n'):
            with self.assertRaises(ValueError):
                MODULE['local_address'](io.StringIO(rows))
        with self.assertRaises(ValueError):
            MODULE['cross_check'](['[persist.vendor.service.bdroid.bdaddr]: [AB:01:00:00:00:02]'], ADDRESS)

    def test_publishes_only_a_new_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'identity'
            MODULE['save_new'](target, ADDRESS)
            self.assertEqual(target.read_bytes(), (ADDRESS + '\n').encode())
            if os.name == 'posix':
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                MODULE['save_new'](target, '02:00:00:00:01:AC')
            self.assertEqual(list(target.parent.iterdir()), [target])
            self.assertEqual(target.read_bytes(), (ADDRESS + '\n').encode())
