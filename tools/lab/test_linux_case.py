"""A restarted private agent may reattach its own media, never shadow foreign data."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('linux_case', Path(__file__).with_name('case-linux-kubuntu.py'))
case = importlib.util.module_from_spec(spec)
spec.loader.exec_module(case)


class MediaMountTests(unittest.TestCase):
    report = {'media_uuid': 'owned-filesystem', 'media_partuuid': 'owned-partition'}
    table = {'partitions': [{'uuid': 'owned-partition', 'node': '/dev/fixture3', 'size': 24 * 1024**3 // 512}]}

    def test_foreign_mounted_filesystem_is_never_replaced(self):
        result = subprocess.CompletedProcess([], 0, 'foreign-filesystem\n', '')
        with patch.object(case.subprocess, 'run', return_value=result), patch.object(case, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'mount identity differs'):
                case.ensure_media(self.report, self.table)
            run.assert_not_called()

    def test_files_under_unmounted_directory_are_never_hidden(self):
        with tempfile.TemporaryDirectory() as folder:
            media = Path(folder)
            (media / 'foreign-file').write_text('keep me')
            result = subprocess.CompletedProcess([], 1, '', '')
            with patch.object(case, 'MEDIA', media), \
                    patch.object(case.subprocess, 'run', return_value=result), \
                    patch.object(case, 'run', return_value='owned-filesystem') as run:
                with self.assertRaisesRegex(ValueError, 'hide existing files'):
                    case.ensure_media(self.report, self.table)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0], 'blkid')
            self.assertEqual((media / 'foreign-file').read_text(), 'keep me')

    def test_restarted_agent_reattaches_verified_existing_media(self):
        with tempfile.TemporaryDirectory() as folder:
            media = Path(folder)
            result = subprocess.CompletedProcess([], 1, '', '')
            with patch.object(case, 'MEDIA', media), \
                    patch.object(case.subprocess, 'run', return_value=result), \
                    patch.object(case, 'run', side_effect=['owned-filesystem', '', 'owned-filesystem']) as run:
                case.ensure_media(self.report, self.table)
                self.assertEqual([c.args[0] for c in run.call_args_list], ['blkid', 'mount', 'findmnt'])
                self.assertEqual(run.call_args_list[1].args, ('mount', 'UUID=owned-filesystem', media))


if __name__ == '__main__':
    unittest.main()
