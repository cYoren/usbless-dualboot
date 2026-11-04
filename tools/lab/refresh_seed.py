#!/usr/bin/env python3
"""Refresh a stopped VM's test payload without replacing credentials or its disk."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import zipfile

from windows_seed import REPO, run


def assert_detached(image):
    option = os.fsencode('file=' + str(image))
    for entry in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = entry.read_bytes().split(b'\0')
        except (OSError, PermissionError):
            continue
        if b'qemu-system-' not in args[0]:
            continue
        if any(option in arg.split(b',') for arg in args):
            raise ValueError('Stop the VM before updating its attached seed image')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=Path, default=REPO / '.lab/seeds/windows-base')
    parser.add_argument('--payload-only', action='store_true', help='Build a host payload without editing attached media')
    args = parser.parse_args()
    folder = args.seed.resolve(strict=True)
    if not folder.is_relative_to(REPO / '.lab'):
        raise ValueError('Seed must remain inside the private repository lab')
    image = folder / 'seed.img'
    for name in ['seed.img', 'agent.json', 'credentials.json', 'Autounattend.xml']:
        if not (folder / name).is_file():
            raise ValueError('An existing seed with original credentials is required')
    if not args.payload_only:
        assert_detached(image)
    source = REPO / 'platforms/windows'
    exe = source / 'bin/Release/usbless.exe'
    pester = REPO / '.lab/cache/Pester.5.7.1.nupkg'
    if not exe.is_file() or not pester.is_file():
        raise ValueError('Build the app and reuse the cached Pester package first')
    next_payload = folder / 'payload.next.zip'
    with zipfile.ZipFile(next_payload, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(exe, 'usbless.exe')
        archive.write(REPO / 'tools/lab/case-fedora-kde.ps1', 'case-fedora-kde.ps1')
        archive.write(exe, 'source/bin/Release/usbless.exe')
        for name in ['engine', 'tests', 'src']:
            for file in sorted((source / name).rglob('*')):
                if file.is_file():
                    archive.write(file, 'source/' + file.relative_to(source).as_posix())
        with zipfile.ZipFile(pester) as package:
            for member in package.infolist():
                if not member.is_dir() and not member.filename.startswith(('_rels/', 'package/')):
                    archive.writestr('Pester/' + member.filename, package.read(member))
    payload = folder / 'payload.zip'
    if payload.exists():
        fingerprint = hashlib.sha256(payload.read_bytes()).hexdigest()
        backup = folder / ('payload.saved-' + fingerprint + '.zip')
        if backup.exists():
            if hashlib.sha256(backup.read_bytes()).hexdigest() != fingerprint:
                raise ValueError('Existing payload backup differs; refusing to overwrite evidence')
        else:
            shutil.copyfile(payload, backup)
    next_payload.replace(payload)
    if args.payload_only:
        print('Built host payload; attached seed media and credentials were not changed.')
        return
    for name in ['guest-agent.ps1', 'windows-layout.cmd']:
        shutil.copyfile(REPO / 'tools/lab' / name, folder / name)
    shutil.copyfile(REPO / 'tools/lab/windows-bootstrap.ps1', folder / 'bootstrap.ps1')
    for name in ['payload.zip', 'guest-agent.ps1', 'windows-layout.cmd', 'bootstrap.ps1']:
        run('mcopy', ['-o', '-i', image, folder / name, '::/' + name])
    print('Refreshed test payload; original credentials, setup XML and VM disk retained.')


if __name__ == '__main__':
    main()
