import io
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'scripts/prepare-bluetooth-identity.py'))
ADDRESS = '02:00:00:00:01:AB'
CACHED = f'[persist.vendor.service.bdroid.bdaddr]: [{ADDRESS}]'
ODM = f'[ro.odm.lenovo.btaddr]: [{ADDRESS.lower()}]'
BOARD = ['[ro.product.vendor.model]: [TB320FC]', '[ro.product.vendor.device]: [TB320FC]']


class BluetoothProvisionTests(unittest.TestCase):
    def test_extracts_local_identity_without_copying_peers(self):
        rows = io.StringIO('[paired-device]\nAddress = FA:00:00:00:00:01\n'
                           f'[Adapter]\nAddress = {ADDRESS.lower()}\n[other]\nAddress = broken\n')
        self.assertEqual(MODULE['local_address'](rows), ADDRESS)
        self.assertEqual(MODULE['property_address']([CACHED], ADDRESS), ADDRESS)

    def test_rejects_ambiguous_or_disagreeing_stock_state(self):
        for rows in ('[Adapter]\nAddress=00:00:00:00:00:00\n', '[peer]\nAddress=' + ADDRESS,
                     f'[Adapter]\nAddress={ADDRESS}\nAddress={ADDRESS}\n'):
            with self.assertRaises(ValueError):
                MODULE['local_address'](io.StringIO(rows))
        with self.assertRaises(ValueError):
            MODULE['property_address'](['[persist.vendor.service.bdroid.bdaddr]: [AB:01:00:00:00:02]'], ADDRESS)

    def test_stock_properties_identify_the_board_and_agree(self):
        self.assertEqual(MODULE['property_address']([CACHED, *BOARD, ODM]), ADDRESS)
        for rows in ([CACHED, ODM], [CACHED, *BOARD], [ODM, *BOARD],
                     [ODM, CACHED, BOARD[0], '[ro.product.vendor.device]: [other]'],
                     [*BOARD, CACHED, ODM, ODM], [*BOARD, CACHED, ODM.replace('ab', 'ac')],
                     [*BOARD, CACHED.replace(ADDRESS, '02:00:00:00:00:00'),
                      '[ro.odm.lenovo.btaddr]: [02:00:00:00:00:00]']):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                MODULE['property_address'](rows)

    def test_adb_reads_fixed_properties_from_only_the_selected_device(self):
        with patch('subprocess.run') as run:
            run.return_value.returncode = 0
            run.return_value.stdout = ('\r\n'.join([CACHED, *BOARD, ODM]) + '\r\n').encode()
            self.assertEqual(MODULE['property_address'](MODULE['adb_properties']('test-unit')), ADDRESS)
            command, = run.call_args.args
            self.assertEqual(command[:-1], ['adb', '-s', 'test-unit', 'shell', '-T'])
            self.assertEqual(command[-1].split(';')[0].split()[3:], list(MODULE['KEYS']))
            self.assertNotIn('test-unit', command[-1])
            run.return_value.returncode = 1
            with self.assertRaises(ValueError):
                MODULE['adb_properties']('test-unit')

    def test_saved_getprop_encodings_used_on_linux_and_windows(self):
        rows = '\r\n'.join([CACHED, *BOARD, ODM])
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / 'getprop.txt'
            for encoding in ('utf-8', 'utf-8-sig', 'utf-16'):
                capture.write_bytes(rows.encode(encoding))
                self.assertEqual(MODULE['saved_address'](capture), ADDRESS)

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
