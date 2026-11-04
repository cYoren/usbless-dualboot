#!/usr/bin/env python3
"""Clone a stopped disposable checkpoint into a new file-backed VM, preserving the source."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import socket
import time
import uuid

from vm import REPO, command, directory, regular_file, request, validate_disk_chain


def clone(source_name, target_name, snapshot, variables, size=None, role='linux-validation', lab=None):
    lab = lab or REPO / '.lab'
    source = directory(source_name, lab).resolve(strict=True)
    target = directory(target_name, lab)
    if target.exists():
        raise ValueError('Destination already exists; completed or partial clones are never overwritten')
    config = json.loads((source / 'vm.json').read_text())
    if config.get('disposable') is not True:
        raise ValueError('Source is not marked disposable')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}', snapshot):
        raise ValueError('Unsafe checkpoint name')
    monitor = source / 'qmp.sock'
    if monitor.exists():
        try:
            request(monitor, 'query-status')
        except (FileNotFoundError, ConnectionRefusedError):
            pass
        else:
            raise ValueError('Shut down the source guest normally before cloning')
    disk = regular_file(source / 'system.qcow2')
    validate_disk_chain(disk, source)
    firmware = regular_file(variables)
    if firmware.parent != source:
        raise ValueError('The checkpoint firmware must be a regular file in its source VM folder')
    info = json.loads(command('qemu-img', ['info', '--output=json', disk]).stdout)
    if not any(item.get('name') == snapshot for item in info.get('snapshots', [])):
        raise ValueError('Named checkpoint is missing; do not substitute the current disk state')
    if size:
        if not re.fullmatch(r'[1-9][0-9]{0,3}G', size) or int(size[:-1]) * 1024**3 < info['virtual-size']:
            raise ValueError('Clone disk size must be a GiB quantity at least as large as its source')
    if role not in ['linux-validation', 'windows-validation']:
        raise ValueError('Unknown lab role')
    os.umask(0o077)
    target.mkdir(parents=True)
    # qemu-img's normal file locking remains enabled. Never use force-shared (-U).
    command('qemu-img', ['convert', '-m', '2', '-l', 'snapshot.name=' + snapshot,
                        '-f', 'qcow2', '-O', 'qcow2', disk, target / 'system.qcow2'])
    if size:
        command('qemu-img', ['resize', '-f', 'qcow2', target / 'system.qcow2', size])
    shutil.copyfile(firmware, target / 'OVMF_VARS.fd')
    config.update(name=target_name, uuid=str(uuid.uuid4()), created_at=int(time.time()),
                  iso=None, disposable=True, role=role,
                  source_checkpoint={'vm': source_name, 'snapshot': snapshot, 'firmware': firmware.name},
                  clone_disk_size=size or str(info['virtual-size']))
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        config['agent_port'] = reservation.getsockname()[1]
    (target / 'vm.json').write_text(json.dumps(config, indent=2) + '\n')
    print(json.dumps({'created': target_name, 'source_preserved': source_name,
                      'snapshot': snapshot, 'uuid': config['uuid'], 'role': role}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('target')
    parser.add_argument('--snapshot', required=True)
    parser.add_argument('--vars', required=True, type=Path)
    parser.add_argument('--size')
    parser.add_argument('--role', choices=['linux-validation', 'windows-validation'], default='linux-validation')
    args = parser.parse_args()
    clone(args.source, args.target, args.snapshot, args.vars, args.size, args.role)


if __name__ == '__main__':
    main()
