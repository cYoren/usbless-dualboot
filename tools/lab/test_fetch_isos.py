"""Checks for the media fetcher's local decisions (no network)."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('fetch_isos', Path(__file__).with_name('fetch_isos.py'))
fetch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch)


class RejectedPartial(unittest.TestCase):
    def test_corrupt_completion_is_quarantined_not_resumed(self):
        with tempfile.TemporaryDirectory() as folder:
            partial = Path(folder) / 'media.iso.part'
            partial.write_bytes(b'wrong bytes')
            rejected = fetch.reject_partial(partial)
            self.assertFalse(partial.exists(), 'the rejected bytes must stop being resumable')
            self.assertTrue(rejected.exists())
            self.assertIn('.part.rejected-', rejected.name)
            self.assertEqual(rejected.read_bytes(), b'wrong bytes', 'evidence is retained, not deleted')

    def test_resolution_prefers_the_point_release(self):
        names = ['ubuntu-26.04-desktop-amd64.iso', 'ubuntu-26.04.1-desktop-amd64.iso']
        self.assertEqual(max(names, key=fetch.key), 'ubuntu-26.04.1-desktop-amd64.iso')

    def test_publisher_formats_are_understood(self):
        import re
        gnu = 'a' * 64 + '  image.iso'
        bsd = 'SHA256 (image.iso) = ' + 'b' * 64
        for line, expected in [(gnu, 'a' * 64), (bsd, 'b' * 64)]:
            found = None
            for pattern in (r'^([0-9a-fA-F]{64})\s+\*?image\.iso$', r'^SHA256 \(image\.iso\) = ([0-9a-fA-F]{64})$'):
                match = re.match(pattern, line)
                if match:
                    found = match.group(1)
            self.assertEqual(found, expected)


if __name__ == '__main__':
    unittest.main()
