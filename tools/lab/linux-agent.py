#!/usr/bin/env python3
"""Authenticated, allowlisted actions in marked disposable Linux lab VMs."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import io
import tarfile
import urllib.request
import sys
import uuid
import shutil


def run(*args):
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=30).stdout.strip()


def assert_lab():
    dmi = Path('/sys/class/dmi/id')
    if (dmi / 'sys_vendor').read_text().strip() != 'USBlessLab' or (dmi / 'product_name').read_text().strip() != 'DisposableVM':
        raise ValueError('Not a marked disposable VM')
    disks = json.loads(run('lsblk', '-dJ', '-o', 'PATH,SERIAL'))['blockdevices']
    if len([disk for disk in disks if (disk.get('serial') or '').strip() == 'USBDBLABSYSTEM']) != 1:
        raise ValueError('Private system disk identity missing or ambiguous')
    if os.geteuid() != 0:
        raise ValueError('Run this private lab helper with sudo inside the guest')


def read_token():
    # The seed stays private: no credentials or configuration are sent to the host.
    seed = Path('/dev/disk/by-label/USBDBSEED').resolve(strict=True)
    if not seed.is_block_device():
        raise ValueError('Seed is not a guest block device')
    # Never use recursive temporary-directory cleanup around mounted storage.
    # If unmount fails, keep the mount untouched for inspection.
    directory = tempfile.mkdtemp(prefix='usbless-lab-seed-')
    mounted = False
    try:
        run('mount', '-o', 'ro,nosuid,nodev,noexec', str(seed), directory)
        mounted = True
        try:
            token = json.loads((Path(directory) / 'agent.json').read_text(encoding='utf-8-sig'))['token']
        finally:
            run('umount', directory)
            mounted = False
    finally:
        if not mounted:
            os.rmdir(directory)
    if not isinstance(token, str) or len(token) < 32:
        raise ValueError('Invalid private lab token')
    return token


def inspect():
    sentinel = Path('/home/usblab/preserve')
    if not sentinel.is_file() or sentinel.stat().st_size == 0:
        raise ValueError('Linux sentinel is missing or empty')
    files = {}
    for folder in ['fedora', 'Microsoft/Boot']:
        base = Path('/boot/efi/EFI') / folder
        for file in base.glob('*.efi'):
            with file.open('rb') as source:
                files[str(file.relative_to('/boot/efi'))] = hashlib.file_digest(source, 'sha256').hexdigest()
    return dict(ok=True, system='linux',
                root=json.loads(run('findmnt', '-J', '/')),
                storage=json.loads(run('lsblk', '-bJ', '-o', 'PATH,TYPE,SIZE,FSTYPE,LABEL,PARTUUID,UUID,MOUNTPOINTS,SERIAL')),
                sentinel=hashlib.sha256(sentinel.read_bytes()).hexdigest(),
                sentinel_path=str(sentinel), efi_loaders=files,
                efi_directories={name: (Path('/boot/efi/EFI') / name).is_dir()
                                 for name in ['Microsoft', 'fedora', 'usbless']},
                firmware=run('efibootmgr', '-v'))


def windows_entry():
    esp = run('findmnt', '-n', '--mountpoint', '/boot/efi', '-o', 'SOURCE')
    uuid = run('blkid', '-s', 'PARTUUID', '-o', 'value', esp).lower()
    if not uuid:
        raise ValueError('ESP identity missing')
    matches = []
    for line in run('efibootmgr', '-v').splitlines():
        match = re.match(r'^Boot([0-9A-Fa-f]{4})\*? Windows Boot Manager\s+HD\(', line)
        if match and uuid in line.lower() and '\\efi\\microsoft\\boot\\bootmgfw.efi' in line.lower():
            matches.append(match.group(1))
    if len(matches) != 1:
        raise ValueError('Windows firmware identity missing or ambiguous')
    return matches[0]


def inspect_live():
    cmdline = Path('/proc/cmdline').read_text().strip()
    if 'boot=casper' not in cmdline.split():
        raise ValueError('This is not a booted Casper live environment')
    return dict(ok=True, system='linux-live', cmdline=cmdline,
                release=Path('/etc/os-release').read_text(), kernel=run('uname', '-r'),
                mounts=json.loads(run('findmnt', '-J', '--list')),
                root=json.loads(run('findmnt', '-J', '/')),
                loop_devices=json.loads(run('losetup', '--list', '--json', '--output', 'NAME,BACK-FILE,BACK-MAJ:MIN')),
                storage=json.loads(run('lsblk', '-bJ', '-o', 'PATH,TYPE,SIZE,FSTYPE,LABEL,PARTUUID,UUID,MOUNTPOINTS,SERIAL,MAJ:MIN')))


def assert_clone(request):
    identity = request.get('vm_identity', '')
    if request.get('vm_role') != 'linux-validation' or not isinstance(identity, str):
        raise ValueError('A designated Linux validation clone is required')
    if str(uuid.UUID(identity)) != identity or identity == '23f093f6-8fb4-42cc-bd37-068295d8c8ae':
        raise ValueError('The original preservation VM must never be prepared as a clone')
    if Path('/sys/class/dmi/id/product_serial').read_text().strip() != identity:
        raise ValueError('Requested clone identity does not match the actual guest')


def test_ext4(request):
    if request.get('action') == 'linux-kubuntu':
        assert_clone(request)
    expected = request.get('source_sha256', '')
    port = request.get('media_port', 8765)
    if not isinstance(expected, str) or not re.fullmatch('[a-fA-F0-9]{64}', expected):
        raise ValueError('Expected source archive hash required')
    if not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ValueError('Invalid private media port')
    with urllib.request.urlopen(f'http://10.0.2.2:{port}/engine.tar', timeout=30) as response:
        source = response.read(4 * 1024 * 1024 + 1)
    if len(source) > 4 * 1024 * 1024 or hashlib.sha256(source).hexdigest() != expected.lower():
        raise ValueError('Incoming engine archive hash/size differs')
    destination = Path(tempfile.mkdtemp(prefix='usbless-engine-', dir='/var/tmp'))
    with tarfile.open(fileobj=io.BytesIO(source), mode='r:') as archive:
        for member in archive.getmembers():
            path = Path(member.name)
            allowed = (member.name in ['bin/usbless-dualboot', 'tools/lab/case-linux-ext4.sh', 'tools/lab/case-linux-cleanup.sh', 'tools/lab/case-linux-repair.sh', 'tools/lab/case-linux-kubuntu.py'] or
                       (path.parent == Path('lib') and path.suffix == '.sh'))
            if not member.isfile() or not allowed or path.is_absolute() or '..' in path.parts:
                raise ValueError('Unexpected member in engine archive')
        archive.extractall(destination, filter='data')
    # Never time out/kill a filesystem operation. A caller timeout retains its state/logs.
    fixture = {'test-cleanup': 'case-linux-cleanup.sh', 'test-repair': 'case-linux-repair.sh'}.get(request.get('action'), 'case-linux-ext4.sh')
    args = ['bash', str(destination / 'tools/lab' / fixture)]
    if request.get('action') == 'linux-kubuntu':
        step = request.get('lab_step')
        if step not in ['prepare', 'fetch', 'plan', 'shrink', 'stage', 'boot-installer', 'restore',
                        'cleanup-preview', 'cleanup', 'repair-preview', 'repair',
                        'plan-windows', 'plan-dry-windows', 'shrink-offline-ext4', 'probe',
                        'chain-fetch', 'chain-plan', 'chain-shrink', 'chain-stage', 'chain-boot', 'chain-inspect', 'chain-free-media', 'chain-relocate-iso']:
            raise ValueError('Unknown Kubuntu lab step')
        args = [sys.executable, str(destination / 'tools/lab/case-linux-kubuntu.py'),
                step, '--vm-identity', request['vm_identity'], '--media-port', str(port)]
        for option, key in (('--distro', 'distro'), ('--iso-name', 'iso_name'),
                            ('--size', 'size'), ('--seed-url', 'seed_url')):
            if request.get(key):
                args += [option, str(request[key])]
    if fixture == 'case-linux-ext4.sh' and request.get('encrypted') is True:
        args.append('--luks')
    result = subprocess.run(args,
                            capture_output=True, text=True)
    if result.returncode:
        return dict(ok=False, source_sha256=expected.lower(), source_dir=str(destination),
                    error=(result.stdout + '\n' + result.stderr)[-5000:])
    report = json.loads(result.stdout.strip().splitlines()[-1])
    return dict(ok=True, source_sha256=expected.lower(), source_dir=str(destination), result=report)


def main():
    assert_lab()
    token = read_token()
    rule = 'rule family="ipv4" source address="10.0.2.2" port port="4777" protocol="tcp" accept'
    firewall = bool(shutil.which('firewall-cmd')) and subprocess.run(['firewall-cmd', '--state'], capture_output=True).returncode == 0
    if firewall:
        run('firewall-cmd', '--add-rich-rule=' + rule)
    try:
        with socket.socket() as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(('0.0.0.0', 4777))
            server.listen(1)
            print('Private Linux lab inspector ready; no arbitrary command execution.', flush=True)
            while True:
                connection, peer = server.accept()
                reboot = False
                poweroff = False
                with connection:
                    connection.settimeout(30)
                    try:
                        if peer[0] != '10.0.2.2':
                            raise ValueError('Not the private QEMU gateway')
                        with connection.makefile('rb') as stream:
                            request = json.loads(stream.readline(4097))
                        if not isinstance(request, dict):
                            raise ValueError('Invalid lab request')
                        provided = request.get('token', '')
                        if not isinstance(provided, str) or not hmac.compare_digest(provided.encode(), token.encode()):
                            raise ValueError('Unauthorized lab request')
                        assert_lab()
                        if request.get('action') in ['status', 'inspect']:
                            response = inspect()
                        elif request.get('action') == 'inspect-live':
                            response = inspect_live()
                        elif request.get('action') in ['test-ext4', 'test-cleanup', 'test-repair', 'linux-kubuntu']:
                            response = test_ext4(request)
                        elif request.get('action') == 'boot-entry':
                            # Explicit firmware entry by number: never inferred.
                            entry = request.get('entry', '')
                            if not isinstance(entry, str) or not re.fullmatch('[0-9A-Fa-f]{4}', entry):
                                raise ValueError('A four-hex-digit firmware entry is required')
                            listing = run('efibootmgr')
                            if f'Boot{entry.upper()}' not in listing:
                                raise ValueError('Requested firmware entry does not exist')
                            run('efibootmgr', '-n', entry.upper())
                            response = dict(ok=True, action='boot-entry', boot_next=entry.upper())
                            reboot = True
                        elif request.get('action') == 'boot-windows':
                            entry = windows_entry()
                            run('efibootmgr', '-n', entry)
                            response = dict(ok=True, action='boot-windows', boot_next=entry)
                            reboot = True
                        elif request.get('action') in ['shutdown', 'reboot']:
                            response = dict(ok=True, action=request['action'])
                            poweroff = request['action'] == 'shutdown'
                            reboot = not poweroff
                        else:
                            raise ValueError('Unknown lab action')
                    except (OSError, ValueError, subprocess.SubprocessError, KeyError) as error:
                        response = dict(ok=False, error=str(error))
                    connection.sendall((json.dumps(response) + '\n').encode())
                if reboot:
                    run('systemctl', 'reboot')
                    break
                if poweroff:
                    run('systemctl', 'poweroff')
                    break
    finally:
        if firewall:
            subprocess.run(['firewall-cmd', '--remove-rich-rule=' + rule], capture_output=True)


if __name__ == '__main__':
    main()
