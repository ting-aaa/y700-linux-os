"""Exercise generated policy and reject invalid/overwriting provisioning inputs."""
import base64
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('provision', Path(__file__).resolve().parents[1] / 'scripts/provision-maintenance.py')
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)
KEY = 'ssh-ed25519 ' + base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20' + bytes(range(32))).decode()


class ProvisionTests(unittest.TestCase):
    def test_unique_identity_and_restricted_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            first, second = Path(tmp)/'one', Path(tmp)/'two'
            for root in first, second:
                provision.generate(root, '192.0.2.1/24', '192.0.2.2', 'tester', KEY)
                config = (root/'etc/y700/maintenance-sshd.conf').read_text()
                self.assertIn('ListenAddress 192.0.2.1\n', config)
                self.assertIn('AllowUsers tester@192.0.2.2\n', config)
                self.assertIn('PermitRootLogin no\nPasswordAuthentication no', config)
                self.assertNotIn('PRIVATE KEY', ''.join(p.read_text() for p in root.rglob('*') if p.is_file()))
            self.assertNotEqual((first/'etc/y700/maintenance.env').read_text(),
                                (second/'etc/y700/maintenance.env').read_text())
            with self.assertRaises(FileExistsError):
                provision.generate(first, '192.0.2.1/24', '192.0.2.2', 'tester', KEY)

    def test_invalid_inputs_do_not_create_output(self):
        cases = [('192.0.2.1/24', '192.0.2.1', 'tester', KEY),
                 ('192.0.2.1/24', '198.51.100.2', 'tester', KEY),
                 ('192.0.2.0/24', '192.0.2.2', 'tester', KEY),
                 ('192.0.2.1/24', '192.0.2.255', 'tester', KEY),
                 ('192.0.2.1/24', '192.0.2.2', 'root', KEY),
                 ('192.0.2.1/24', '192.0.2.2', 'tester\nroot', KEY),
                 ('192.0.2.1/24', '192.0.2.2', 'tester', 'ssh-ed25519 AAAA')]
        with tempfile.TemporaryDirectory() as tmp:
            for args in cases:
                with self.subTest(args=args[:3]), self.assertRaises(ValueError):
                    provision.generate(Path(tmp)/'bad', *args)
                self.assertFalse((Path(tmp)/'bad').exists())


if __name__ == '__main__':
    unittest.main()
