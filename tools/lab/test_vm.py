"""Host-independent guard and keyboard tests; no VM process is started."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import refresh_seed

spec = importlib.util.spec_from_file_location('lab_vm', Path(__file__).with_name('vm.py'))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class LabGuards(unittest.TestCase):
    def test_rejects_host_devices_and_path_option_injection(self):
        with self.assertRaises(ValueError):
            vm.regular_file('/dev/null')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'disk,format=raw'
            path.touch()
            with self.assertRaises(ValueError):
                vm.regular_file(path)

    def test_rejects_vm_path_traversal(self):
        for name in ['../system', '/tmp/other', 'a/b', '']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                vm.directory(name, Path('/tmp/lab'))

    def test_unsupported_text_sends_nothing_to_guest(self):
        with patch.object(vm, 'send_keys') as send:
            with self.assertRaises(ValueError):
                vm.type_text(Path('/tmp/lab'), 'echo partial\U0001f600', 'de')
            send.assert_not_called()

    def test_key_combination_releases_keys_in_reverse_order(self):
        with patch.object(vm, 'request') as request, patch.object(vm.time, 'sleep'):
            vm.send_keys(Path('/tmp/lab'), ['shift', 'a'])
            events = [c.args[2]['events'] for c in request.call_args_list]
            self.assertEqual([(e['data']['key']['data'], e['data']['down']) for e in events[0]],
                             [('shift', True), ('a', True)])
            self.assertEqual([(e['data']['key']['data'], e['data']['down']) for e in events[1]],
                             [('a', False), ('shift', False)])

    def test_key_combination_releases_keys_when_interrupted(self):
        with patch.object(vm, 'request') as request, patch.object(vm.time, 'sleep', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                vm.send_keys(Path('/tmp/lab'), ['ctrl', 'c'])
            self.assertTrue(all(not e['data']['down'] for e in request.call_args_list[-1].args[2]['events']))

    def test_german_diagnostic_path_and_wildcard(self):
        with patch.object(vm, 'send_keys') as send, patch.object(vm.time, 'sleep'):
            vm.type_text(Path('/tmp/lab'), '\\*:~>', 'de')
            self.assertEqual([c.args[1] for c in send.call_args_list], [
                ['alt_r', 'minus'], ['shift', 'bracket_right'], ['shift', 'dot'],
                ['alt_r', 'bracket_right'], ['shift', 'less']])

    def test_us_home_shortcut_uses_qmp_grave_accent_key(self):
        with patch.object(vm, 'send_keys') as send, patch.object(vm.time, 'sleep'):
            vm.type_text(Path('/tmp/lab'), '~`', 'us')
            self.assertEqual([c.args[1] for c in send.call_args_list], [
                ['shift', 'grave_accent'], ['grave_accent']])

    def test_click_rejects_coordinates_outside_current_screen(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'screen.ppm').write_bytes(b'P6\n1280 800\n255\n')
            for x, y in [(-1, 0), (1280, 10), (10, 800)]:
                with self.subTest(x=x, y=y), patch.object(vm, 'request') as request:
                    with self.assertRaisesRegex(ValueError, 'inside'):
                        vm.click_point(folder, x, y)
                    self.assertEqual([c.args[1] for c in request.call_args_list], ['screendump'])

    def test_click_requires_absolute_pointer_and_releases_button(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'screen.ppm').write_bytes(b'P6\n1280 800\n255\n')
            def reply(monitor, operation, arguments=None):
                return [{'current': True, 'absolute': True}] if operation == 'query-mice' else {}
            with patch.object(vm, 'request', side_effect=reply) as request, patch.object(vm.time, 'sleep'):
                vm.click_point(folder, 1279, 799)
                events = [c.args[2]['events'] for c in request.call_args_list if c.args[1] == 'input-send-event']
                self.assertEqual([e['data']['value'] for e in events[0]], [32767, 32767])
                self.assertTrue(events[1][0]['data']['down'])
                self.assertFalse(events[2][0]['data']['down'])
            with patch.object(vm, 'request', side_effect=[{}, [{'current': True, 'absolute': False}]]):
                with self.assertRaisesRegex(ValueError, 'absolute pointer'):
                    vm.click_point(folder, 10, 10)

    def test_tpm_cleanup_leaves_other_vms_and_unrelated_processes(self):
        folder = Path('/tmp/lab/vms/one')
        own = Mock()
        own.parent = SimpleNamespace(name='123')
        own.read_bytes.return_value = (str(vm.TOOLS / 'usr/bin/swtpm') + '\0socket\0' +
                                      'type=unixio,path=/tmp/lab/vms/one/tpm.sock\0').encode()
        other = Mock()
        other.read_bytes.return_value = own.read_bytes.return_value.replace(b'/one/', b'/two/')
        unrelated = Mock()
        unrelated.read_bytes.return_value = b'/usr/bin/other\0type=unixio,path=/tmp/lab/vms/one/tpm.sock\0'
        with patch.object(vm.Path, 'glob', return_value=[own, other, unrelated]), patch.object(vm.os, 'kill') as kill:
            vm.stop_tpm(folder)
            kill.assert_called_once_with(123, vm.signal.SIGTERM)

    def test_seed_refresh_refuses_live_attachment(self):
        image = Path('/tmp/lab/seeds/seed.img')
        process = Mock()
        process.read_bytes.return_value = b'/bin/qemu-system-x86_64\0-drive\0if=none,file=/tmp/lab/seeds/seed.img\0'
        with patch.object(refresh_seed.Path, 'glob', return_value=[process]):
            with self.assertRaisesRegex(ValueError, 'Stop the VM'):
                refresh_seed.assert_detached(image)

    def test_seed_refresh_does_not_confuse_similar_filename(self):
        process = Mock()
        process.read_bytes.return_value = b'/bin/qemu-system-x86_64\0-drive\0file=/tmp/lab/seeds/seed.img.other\0'
        with patch.object(refresh_seed.Path, 'glob', return_value=[process]):
            refresh_seed.assert_detached(Path('/tmp/lab/seeds/seed.img'))

    def test_monitor_permission_failure_never_removes_live_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'vm.json').write_text(json.dumps({'disposable': True}))
            (folder / 'system.qcow2').touch()
            (folder / 'qmp.sock').touch()
            with patch.object(vm, 'request', side_effect=PermissionError('sandbox')), patch.object(vm, 'stop_tpm') as stop:
                with self.assertRaises(PermissionError):
                    vm.start(SimpleNamespace(name='test', offline=True), folder)
                stop.assert_not_called()
            self.assertTrue((folder / 'qmp.sock').exists())

    def test_snapshot_backing_cannot_escape_private_vm(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / 'vm'
            folder.mkdir()
            disk = folder / 'system.qcow2'
            disk.touch()
            outside = Path(tmp) / 'unrelated-data.img'
            outside.touch()
            result = SimpleNamespace(stdout=json.dumps([{'filename': str(disk)}, {'filename': str(outside)}]))
            with patch.object(vm, 'command', return_value=result), self.assertRaisesRegex(ValueError, 'Backing disks'):
                vm.validate_disk_chain(disk, folder)

    def test_snapshot_accepts_local_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            disk = folder / 'system.qcow2'
            baseline = folder / 'baseline.qcow2'
            disk.touch()
            baseline.touch()
            result = SimpleNamespace(stdout=json.dumps([{'filename': str(disk)}, {'filename': str(baseline)}]))
            with patch.object(vm, 'command', return_value=result):
                vm.validate_disk_chain(disk, folder)


if __name__ == '__main__':
    unittest.main()
