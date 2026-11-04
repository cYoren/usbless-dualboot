"""BootNext selection must never choose another ESP, another loader or duplicates."""
import importlib.util
from pathlib import Path
import unittest
import subprocess
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('linux_lab_agent', Path(__file__).with_name('linux-agent.py'))
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class WindowsBootIdentityTests(unittest.TestCase):
    uuid = '196ef89b-59df-4668-92fd-31624e068f62'

    def entry(self, name='Windows Boot Manager', uuid=None, loader='\\EFI\\Microsoft\\Boot\\bootmgfw.efi'):
        return f'Boot0009* {name}\tHD(1,GPT,{uuid or self.uuid},0x800,0x100000)/{loader}'

    def select(self, entries):
        with patch.object(agent, 'run', side_effect=['/dev/sda1', self.uuid, entries]):
            return agent.windows_entry()

    def test_exact_installed_windows_entry(self):
        self.assertEqual(self.select(self.entry()), '0009')

    def test_another_esp_is_refused(self):
        with self.assertRaises(ValueError):
            self.select(self.entry(uuid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'))

    def test_another_loader_is_refused(self):
        with self.assertRaises(ValueError):
            self.select(self.entry(loader='\\EFI\\usbless\\BOOTX64.EFI'))

    def test_similar_title_is_refused(self):
        with self.assertRaises(ValueError):
            self.select(self.entry(name='Windows Boot Manager (unrelated)'))

    def test_duplicate_windows_entries_are_refused(self):
        with self.assertRaises(ValueError):
            self.select(self.entry() + '\n' + self.entry().replace('0009', '000B'))

    def test_missing_esp_uuid_is_refused(self):
        with patch.object(agent, 'run', side_effect=['/dev/sda1', '']):
            with self.assertRaises(ValueError):
                agent.windows_entry()


class SeedMountSafetyTests(unittest.TestCase):
    def read_seed(self, unmount_error=None):
        def command(*args):
            if args[0] == 'umount' and unmount_error:
                raise unmount_error
            return ''
        with patch.object(Path, 'resolve', return_value=Path('/dev/fixture')), \
             patch.object(Path, 'is_block_device', return_value=True), \
             patch.object(Path, 'read_text', return_value='{"token":"' + 'a' * 64 + '"}'), \
             patch.object(agent.tempfile, 'mkdtemp', return_value='/tmp/private-seed-test'), \
             patch.object(agent.os, 'rmdir') as remove_empty, \
             patch.object(agent, 'run', side_effect=command):
            if unmount_error:
                with self.assertRaises(subprocess.CalledProcessError):
                    agent.read_token()
                remove_empty.assert_not_called()
            else:
                self.assertEqual(agent.read_token(), 'a' * 64)
                remove_empty.assert_called_once_with('/tmp/private-seed-test')

    def test_unmount_failure_preserves_mount(self):
        self.read_seed(subprocess.CalledProcessError(32, ['umount']))

    def test_success_removes_only_empty_mount_directory(self):
        self.read_seed()


if __name__ == '__main__':
    unittest.main()
