import hashlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fetch_inputs', Path(__file__).resolve().parents[1]/'scripts/fetch-debian-inputs.py')
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class DownloadIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.payload = b'archive-integrity-test'
        self.item = dict(package='fixture', size=len(self.payload),
                         sha256=hashlib.sha256(self.payload).hexdigest(),
                         uri='https://deb.debian.org/debian/pool/fixture.deb')

    def test_valid_cache_needs_no_network(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory/f"{self.item['sha256']}.deb").write_bytes(self.payload)
            with patch.object(fetcher.urllib.request, 'urlopen') as request:
                self.assertEqual(fetcher.fetch(self.item, directory), 'cached')
                request.assert_not_called()

    def test_bad_cache_is_preserved_and_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            target = directory/f"{self.item['sha256']}.deb"
            target.write_bytes(b'bad')
            with self.assertRaises(ValueError):
                fetcher.fetch(self.item, directory)
            self.assertEqual(target.read_bytes(), b'bad')

    def test_bad_or_oversized_download_is_never_published(self):
        for data in (b'bad', self.payload+b'extra'):
            with self.subTest(data=data), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                with patch.object(fetcher.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                    with self.assertRaises(ValueError):
                        fetcher.fetch(self.item, directory)
                self.assertEqual(list(directory.iterdir()), [])

    def test_unapproved_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                fetcher.fetch({**self.item, 'uri': 'http://deb.debian.org/fixture.deb'}, Path(temp))
            self.assertEqual(list(Path(temp).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
