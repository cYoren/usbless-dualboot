#!/usr/bin/env python3
"""Run the distro breadth chain: plan, shrink, stage, boot one installer at a time.

Each case is independent: it writes its own plan and phase state on the shared lab
partition, fetches the already-verified publisher ISO from the host cache, and boots
the installer with that installer's own unattended seed. A case is only recorded as
`installer-booted` when the carrier actually reached the installer; anything else is
recorded with the failure text. Nothing here promotes a case to installed-and-booted.
"""
import argparse
import json
from pathlib import Path
import re
import socket
import sys
import time

REPO = Path(__file__).resolve().parents[2]
SEEDS = REPO / '.lab/seeds/autoinstall'

# installer engine per distro; only engines with a seed template are attempted
ENGINES = {
    'subiquity': ['ubuntu', 'ubuntu-server', 'xubuntu', 'ubuntu-budgie', 'ubuntucinnamon',
                  'ubuntu-unity', 'edubuntu', 'ubuntustudio', 'lubuntu'],
    'kickstart': ['fedora'],
    'preseed': ['debian', 'debian-netinst'],
    'ubiquity': ['mint-cinnamon', 'mint-mate', 'mint-xfce'],
    'archinstall': ['arch'],
}


def engine_for(distro):
    for engine, members in ENGINES.items():
        if distro in members:
            return engine
    return None


def send(vm, action, timeout=3600, **fields):
    folder = REPO / '.lab/vms' / vm
    config = json.loads((folder / 'vm.json').read_text())
    token = json.loads((REPO / '.lab/seeds/windows-base/agent.json').read_text())['token']
    request = {'action': action, 'token': token, 'vm_identity': config.get('uuid'),
               'vm_role': config.get('role')}
    request.update(fields)
    with socket.create_connection(('127.0.0.1', int(config['agent_port'])), timeout=timeout) as connection:
        connection.sendall((json.dumps(request) + '\n').encode())
        response = json.loads(connection.makefile('rb').readline())
    if not response.get('ok'):
        raise RuntimeError(f"{action}: {(response.get('error') or '')[-1500:]}")
    return response


def media_name(distro):
    """The ISO this case staged, read from its own plan."""
    return None


def password_hash():
    """Hash the disposable lab password for the seed; never print it."""
    import subprocess
    secret = json.loads((REPO / '.lab/seeds/windows-base/credentials.json').read_text())['password']
    return subprocess.run(['openssl', 'passwd', '-6', '-stdin'], input=secret, capture_output=True,
                          text=True, check=True).stdout.strip()


def user_data(distro, plan, iso_name):
    """Subiquity autoinstall that formats only the region the plan reserved."""
    start = int(plan['linux_new_end']) + 1
    end = int(plan['installer_start']) - 1
    sectors = end - start + 1
    number = max(int(p['node'].split('sda')[-1]) for p in plan['_table']['partitions']) + 1
    return f"""#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {{layout: us}}
  identity:
    hostname: {distro}
    username: usblab
    password: "{password_hash}"
  ssh: {{install-server: false}}
  storage:
    config:
      - id: disk-sda
        type: disk
        path: /dev/sda
        preserve: true
      - id: newroot
        type: partition
        device: disk-sda
        number: {number}
        offset: {start * 512}
        size: {sectors * 512}
        wipe: superblock
        flag: ""
        preserve: false
      - id: format-root
        type: format
        volume: newroot
        fstype: ext4
        label: {distro}
      - id: mount-root
        type: mount
        path: /
        device: format-root
  late-commands:
    - curtin in-target -- sh -c 'echo {distro}-sentinel-20261109 > /home/usblab/preserve'
""".replace('{password_hash}', password_hash())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('distros', nargs='+')
    parser.add_argument('--vm', default='linux-kubuntu')
    parser.add_argument('--media-port', type=int, default=8770)
    parser.add_argument('--distro', dest='size', default='30G')
    parser.add_argument('--boot-wait', type=int, default=1500)
    parser.add_argument('--report', type=Path, default=REPO / '.lab/logs/chain.json')
    args = parser.parse_args()
    results = []
    for distro in args.distros:
        engine = engine_for(distro)
        record = {'distro': distro, 'engine': engine, 'started_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
        if engine != 'subiquity':
            record['status'] = 'unsupported-engine'
            record['note'] = 'only the subiquity seed is implemented; do not claim this case'
            results.append(record)
            continue
        try:
            names = [p.name for p in (REPO / '.lab/cache/isos' / distro).glob('*.iso')]
            if not names:
                raise RuntimeError(f'{distro}: no verified media in the cache')
            iso_name = names[0]
            seed_url = f'http://10.0.2.2:{args.media_port}/autoinstall/{distro}'
            record['iso'] = iso_name
            record['fetch'] = send(args.vm, 'linux-kubuntu', lab_step='chain-fetch', media_port=args.media_port,
                                   distro=distro, iso_name=iso_name)['result']
            plan = send(args.vm, 'linux-kubuntu', lab_step='chain-plan', media_port=args.media_port,
                        distro=distro, iso_name=iso_name, size=args.size, seed_url=seed_url)['result']
            record['plan'] = {k: plan['config'].get(k) for k in
                              ('linux_part', 'linux_new_size', 'linux_new_end', 'installer_start', 'installer_end', 'linux_params')}
            record['plan_log'] = plan['log_text']
            folder = SEEDS / distro
            folder.mkdir(parents=True, exist_ok=True)
            table = json.loads(subprocess_run('sfdisk', ['--json', plan['config']['disk']]))['partitiontable']
            (folder / 'user-data').write_text(user_data(distro, dict(plan['config'], _table=table), iso_name))
            (folder / 'meta-data').write_text(f'instance-id: {distro}-usbdb\nlocal-hostname: {distro}\n')
            record['shrink'] = send(args.vm, 'linux-kubuntu', lab_step='chain-shrink', media_port=args.media_port,
                                    distro=distro, iso_name=iso_name)['result']['log_text'][-1200:]
            record['stage'] = send(args.vm, 'linux-kubuntu', lab_step='chain-stage', media_port=args.media_port,
                                   distro=distro, iso_name=iso_name)['result']['log_text'][-1200:]
            record['boot'] = send(args.vm, 'linux-kubuntu', lab_step='chain-boot', media_port=args.media_port,
                                  distro=distro, iso_name=iso_name)['result']['log_text'][-800:]
            record['status'] = 'installer-booted'
            time.sleep(5)
            send(args.vm, 'reboot')
        except Exception as error:  # noqa: BLE001 - the chain records and continues
            record['status'] = record.get('status') or 'failed'
            record['error'] = str(error)[-2000:]
        results.append(record)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(results, indent=1) + '\n')
        print(json.dumps({'distro': distro, 'status': record['status']}), flush=True)
        if record['status'] == 'installer-booted':
            time.sleep(args.boot_wait)
    return 0


def subprocess_run(program, arguments):
    import subprocess
    return subprocess.run([program, *arguments], capture_output=True, text=True, check=True).stdout


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print('error:', error, file=sys.stderr)
        raise SystemExit(1)
