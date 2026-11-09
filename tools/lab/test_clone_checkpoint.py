#!/usr/bin/env python3
"""Checkpoint cloning must refuse unsafe sources without starting disk writes."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import clone_checkpoint as helper


class CloneSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='usbdb-clone-test-')
        self.addCleanup(self.temporary.cleanup)
        self.lab = Path(self.temporary.name)
        self.source = self.lab / 'vms/source'
        self.source.mkdir(parents=True)
        (self.source / 'vm.json').write_text(json.dumps({'disposable': True}))
        self.disk = self.source / 'system.qcow2'
        self.disk.write_bytes(b'untouched source disk')
        self.firmware = self.source / 'checkpoint.fd'
        self.firmware.write_bytes(b'untouched firmware')

    def invoke(self):
        return helper.clone('source', 'target', 'saved-state', self.firmware, lab=self.lab)

    def test_existing_destination_is_never_overwritten(self):
        target = self.lab / 'vms/target'
        target.mkdir()
        marker = target / 'system.qcow2'
        marker.write_bytes(b'existing partial clone')
        with patch.object(helper, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'Destination already exists'):
                self.invoke()
            command.assert_not_called()
        self.assertEqual(marker.read_bytes(), b'existing partial clone')

    def test_registered_data_disks_are_validated(self):
        (self.source / 'vm.json').write_text(json.dumps({'disposable': True, 'extra_disks': [
            {'file': 'data-USBDBLABDATA.qcow2', 'serial': 'USBDBLABDATA'}]}))
        with self.assertRaises(FileNotFoundError):
            helper.data_disks(self.source, json.loads((self.source / 'vm.json').read_text()))
        (self.source / 'data-USBDBLABDATA.qcow2').write_bytes(b'data')
        self.assertEqual([p.name for p in helper.data_disks(self.source, json.loads((self.source / 'vm.json').read_text()))],
                         ['data-USBDBLABDATA.qcow2'])

    def test_unsafe_data_disk_names_are_refused(self):
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            helper.data_disks(self.source, {'extra_disks': [{'file': '../escape.qcow2'}]})

    def test_running_source_is_rejected_before_disk_access(self):
        (self.source / 'qmp.sock').touch()
        with patch.object(helper, 'request', return_value={'running': True}), \
                patch.object(helper, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'Shut down the source'):
                self.invoke()
            command.assert_not_called()
        self.assertFalse((self.lab / 'vms/target').exists())
        self.assertEqual(self.disk.read_bytes(), b'untouched source disk')

    def test_missing_checkpoint_never_falls_back_to_current_disk(self):
        with patch.object(helper, 'validate_disk_chain'), \
                patch.object(helper, 'command') as command:
            command.return_value.stdout = json.dumps({'snapshots': [], 'virtual-size': 1024**3})
            with self.assertRaisesRegex(ValueError, 'Named checkpoint is missing'):
                self.invoke()
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[1][0], 'info')
        self.assertFalse((self.lab / 'vms/target').exists())
        self.assertEqual(self.disk.read_bytes(), b'untouched source disk')


if __name__ == '__main__':
    unittest.main()
