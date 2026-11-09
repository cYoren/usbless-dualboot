#!/usr/bin/env python3
"""Fixed Kubuntu installation case, ONLY inside a separately identified disposable clone.

The prepare step deliberately replaces the clone's Windows/WinRE partitions with
lab media storage. It never runs in the original preservation VM. Fedora, its data,
boot partition and ESP are the incumbent system for this new, independent case.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

ORIGINAL_VM = '23f093f6-8fb4-42cc-bd37-068295d8c8ae'
DISK_GUID = '0383d3f0-1e84-4e59-8c14-b2a1b504ec4f'
ROOT_GUID = 'da255634-cd51-4db0-b4c1-07e2e195f6c2'
WINDOWS_GUID = 'afe7c143-06c7-4812-93fe-8bf3defe3c32'
RECOVERY_GUID = 'fbfedaf4-c5c2-40b9-a9ef-5c255165415e'
EXPECTED = {
    '196ef89b-59df-4668-92fd-31624e068f62': (1048576, 536870912),
    'c4147001-2d51-48cc-82fa-9268139fbd1e': (537919488, 16777216),
    WINDOWS_GUID: (554696704, 109203947520),
    '53f33539-4c82-40b7-80fd-e739ab190d02': (109758644224, 2147483648),
    ROOT_GUID: (111906127872, 24696061952),
    RECOVERY_GUID: (136602189824, 834666496),
}
ISO_NAME = 'kubuntu-26.10-desktop-amd64.iso'
WINDOWS_NAME = 'win11-lab.iso'
WINDOWS_BYTES = 8489097216
ISO_BYTES = 5141966848
ISO_SHA256 = '8160b1d6266dfe1998d183b19713680263c09669f101e0e41cbcf11f50b6f785'
STATE = Path('/var/lib/USBlessLab/kubuntu')
MEDIA = Path('/mnt/usbdb-lab-media')
STATE_WINDOWS = MEDIA / 'state-windows'


def run(*args, input=None, env=None):
    # No worker timeout: preserve recovery state rather than kill storage writes.
    result = subprocess.run(list(map(str, args)), input=input, env=env,
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): '
                           f'{result.stdout[-2500:]}\n{result.stderr[-2500:]}')
    return result.stdout.strip()


def guarded_disk(identity, incumbent='fedora'):
    dmi = Path('/sys/class/dmi/id')
    if (identity == ORIGINAL_VM or str(uuid.UUID(identity)) != identity or
            (dmi / 'product_serial').read_text().strip() != identity or
            (dmi / 'sys_vendor').read_text().strip() != 'USBlessLab' or
            (dmi / 'product_name').read_text().strip() != 'DisposableVM' or os.geteuid() != 0):
        raise ValueError('A different, explicitly identified disposable clone is required')
    disks = json.loads(run('lsblk', '-dJ', '-o', 'PATH,SERIAL'))['blockdevices']
    matches = [d['path'] for d in disks if (d.get('serial') or '').strip() == 'USBDBLABSYSTEM']
    if len(matches) != 1:
        raise ValueError('Clone system disk missing or ambiguous')
    disk = matches[0]
    if int(run('blockdev', '--getsize64', disk)) != 256 * 1024**3 or run('blockdev', '--getss', disk) != '512':
        raise ValueError('This fixed case requires the separate 256 GiB clone')
    table = json.loads(run('sfdisk', '--json', disk))['partitiontable']
    if table['label'] != 'gpt' or table['id'].strip('{}').lower() != DISK_GUID:
        raise ValueError('Clone disk GUID differs')
    root = run('findmnt', '-n', '-o', 'SOURCE', '/').split('[')[0]
    root_uuid = run('blkid', '-s', 'PARTUUID', '-o', 'value', root).lower()
    if incumbent == 'fedora':
        if root_uuid != ROOT_GUID:
            raise ValueError('Run this step from the preserved Fedora incumbent')
    elif incumbent == 'any':
        pass
    elif incumbent == 'kubuntu':
        # The installed Kubuntu root is the ext4 partition created inside the
        # planned region; it must not be the Fedora root.
        if root_uuid == ROOT_GUID or run('blkid', '-s', 'TYPE', '-o', 'value', root) != 'ext4':
            raise ValueError('Run this step from the installed Kubuntu system')
        start = int((Path('/sys/class/block') / Path(root).name / 'start').read_text())
        if start != 264704000:
            raise ValueError('The Kubuntu root is not inside the planned region')
    else:
        raise ValueError('Unknown incumbent')
    return disk, table


def run_both(*args, env=None):
    result = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True)
    text = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): ' + text[-2500:])
    return text


def save(report):
    target = STATE / 'state.json'
    temp = target.with_suffix('.new')
    temp.write_text(json.dumps(report, indent=2) + '\n')
    temp.replace(target)
    run('sync', '-f', target)


def ensure_media(report, table):
    probe = subprocess.run(['findmnt', '-n', '--mountpoint', str(MEDIA), '-o', 'UUID'],
                           capture_output=True, text=True)
    if probe.returncode == 0:
        if probe.stdout.strip() != report['media_uuid']:
            raise ValueError('Lab media mount identity differs')
        return
    if probe.returncode != 1:
        raise ValueError('Could not inspect the lab media mount')
    matches = [p for p in table['partitions'] if p['uuid'].lower() == report['media_partuuid']]
    if len(matches) != 1 or matches[0]['size'] * 512 != 24 * 1024**3:
        raise ValueError('Saved lab media partition is missing or changed')
    device = matches[0]['node']
    if run('blkid', '-s', 'UUID', '-o', 'value', device) != report['media_uuid']:
        raise ValueError('Saved lab media filesystem differs')
    if not MEDIA.is_dir() or any(MEDIA.iterdir()):
        raise ValueError('Refusing to hide existing files beneath the lab media mount')
    # Each agent has a private mount namespace; reattach existing storage only.
    run('mount', 'UUID=' + report['media_uuid'], MEDIA)
    if run('findmnt', '-n', '--mountpoint', MEDIA, '-o', 'UUID') != report['media_uuid']:
        raise ValueError('Lab media mount identity differs after mounting')


def ensure_lab_media():
    """Attach the shared lab partition by its own label, from either installed system.

    The Kubuntu case state lives on Fedora's root, so steps that run from the
    installed Kubuntu must not depend on it; the partition label is the identity
    that both systems can see.
    """
    MEDIA.mkdir(parents=True, exist_ok=True)
    probe = subprocess.run(['findmnt', '-n', '--mountpoint', str(MEDIA), '-o', 'LABEL'],
                           capture_output=True, text=True)
    if probe.returncode == 0:
        if probe.stdout.strip() != 'USBDBLABMEDIA':
            raise ValueError('The lab media mount point carries a different filesystem')
        return
    if probe.returncode != 1:
        raise ValueError('Could not inspect the lab media mount point')
    matches = run('blkid', '-L', 'USBDBLABMEDIA').split()
    if len(matches) != 1 or not Path(matches[0]).is_block_device():
        raise ValueError('The shared lab media partition was not found by label')
    device = matches[0]
    if run('blkid', '-s', 'TYPE', '-o', 'value', device) != 'ext4':
        raise ValueError('The shared lab media partition is not ext4')
    if any(MEDIA.iterdir()):
        raise ValueError('Refusing to hide existing files beneath the lab media mount')
    run('mount', device, MEDIA)
    print(json.dumps(dict(media_device=device)), file=sys.stderr, flush=True)


def prepare(identity, disk, table):
    target = STATE / 'state.json'
    if target.exists():
        report = json.loads(target.read_text())
        if report.get('vm_identity') == identity and report.get('prepared') is True:
            return dict(already_prepared=True, state=str(target), media_uuid=report['media_uuid'])
        raise ValueError('Preparation state already exists; inspect it, never reset or repeat writes')
    actual = {p['uuid'].lower(): (p['start'] * 512, p['size'] * 512) for p in table['partitions']}
    if actual != EXPECTED:
        raise ValueError('Clone partition identities/ranges differ from the preserved checkpoint')
    selected = [p for p in table['partitions'] if p['uuid'].lower() in [WINDOWS_GUID, RECOVERY_GUID]]
    for part in selected:
        if run('lsblk', '-n', '-o', 'MOUNTPOINTS', part['node']):
            raise ValueError('A clone partition selected for replacement is mounted')
        if list((Path('/sys/class/block') / Path(part['node']).name / 'holders').iterdir()):
            raise ValueError('A clone partition selected for replacement has holders')
    STATE.mkdir(parents=True, mode=0o700)
    (STATE / 'before.json').write_text(json.dumps(table, indent=2) + '\n')
    (STATE / 'before.sfdisk').write_text(run('sfdisk', '--dump', disk) + '\n')
    run('sfdisk', '--backup-pt-sectors', '--backup-file', STATE / 'gpt', disk)
    sentinel = Path('/home/usblab/preserve')
    report = dict(vm_identity=identity, disk=disk, disk_guid=DISK_GUID,
                  phase_in_progress='prepare-clone', prepared=False,
                  preserved_sentinel=hashlib.sha256(sentinel.read_bytes()).hexdigest(),
                  replaced_partition_guids=[WINDOWS_GUID, RECOVERY_GUID],
                  media_partuuid=str(uuid.uuid4()))
    save(report)
    options = ['--no-reread', '--no-tell-kernel']
    run('sfdisk', *options, '--relocate', 'gpt-bak-std', disk)
    numbers = [(Path('/sys/class/block') / Path(p['node']).name / 'partition').read_text().strip()
               for p in selected]
    run('sfdisk', *options, '--delete', disk, *numbers)
    for number in numbers:
        run('partx', '-d', '--nr', number, disk)
    run('sfdisk', *options, '--append', '--wipe', 'never', '--wipe-partitions', 'never', disk,
        input=f'start={554696704 // 512}, size={24 * 1024**3 // 512}, type=L, '
              f'uuid={report["media_partuuid"]}, name="USBDBLABMEDIA"\n')
    after = json.loads(run('sfdisk', '--json', disk))['partitiontable']
    kept = {p['uuid'].lower(): (p['start'] * 512, p['size'] * 512)
            for p in after['partitions'] if p['uuid'].lower() in EXPECTED}
    if kept != {k: v for k, v in EXPECTED.items() if k not in [WINDOWS_GUID, RECOVERY_GUID]}:
        raise ValueError('Incumbent partition ranges changed unexpectedly; keep backups and stop')
    media = next(p for p in after['partitions'] if p['uuid'].lower() == report['media_partuuid'])
    if media['start'] * 512 != 554696704 or media['size'] * 512 != 24 * 1024**3:
        raise ValueError('New lab media range differs')
    # Resolve the new slot from GPT rather than assuming a partition number.
    number = str(int(media['node'].removeprefix(disk).removeprefix('p')))
    run('partx', '-a', '--nr', number, disk)
    run('udevadm', 'settle')
    if run('blkid', '-s', 'PARTUUID', '-o', 'value', media['node']).lower() != report['media_partuuid']:
        raise ValueError('Kernel media identity differs; refusing to format')
    run('mkfs.ext4', '-F', '-L', 'USBDBLABMEDIA', media['node'])
    report['media_uuid'] = run('blkid', '-s', 'UUID', '-o', 'value', media['node'])
    MEDIA.mkdir(parents=True, exist_ok=True)
    run('mount', 'UUID=' + report['media_uuid'], MEDIA)
    fstab = Path('/etc/fstab')
    line = f'UUID={report["media_uuid"]} {MEDIA} ext4 defaults,nofail 0 2\n'
    with fstab.open('a') as output:
        output.write('\n# USBless disposable clone lab media\n' + line)
    (STATE / 'after.json').write_text(json.dumps(after, indent=2) + '\n')
    if hashlib.sha256(sentinel.read_bytes()).hexdigest() != report['preserved_sentinel']:
        raise ValueError('Fedora sentinel differs after clone provisioning')
    report.update(prepared=True, phase_in_progress=None)
    save(report)
    return report


def ensure_windows_media():
    """Copy the lab's Windows media onto the shared lab partition exactly once.

    The plan and the later offline shrink both hash this file, so it must live on
    storage visible to both installed systems rather than on either root.
    """
    target = MEDIA / WINDOWS_NAME
    if target.exists():
        if target.stat().st_size != WINDOWS_BYTES:
            raise ValueError('Existing Windows media differs from the user ISO size; inspect instead of replacing')
        return target
    source = Path('/dev/sr0')
    if not source.exists():
        raise ValueError('The Windows ISO is not attached as a read-only optical device')
    if int(run('blockdev', '--getsize64', source)) != WINDOWS_BYTES:
        raise ValueError('Attached optical device is not the expected Windows media')
    partial = target.with_suffix('.iso.part')
    if partial.exists():
        partial.unlink()
    run('dd', f'if={source}', f'of={partial}', 'bs=8M', 'status=none')
    if partial.stat().st_size != WINDOWS_BYTES:
        raise ValueError('Copied Windows media has the wrong size')
    partial.rename(target)
    run('sync', '-f', target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('step', choices=['prepare', 'fetch', 'plan', 'shrink', 'stage', 'boot-installer',
                                         'repair-preview', 'repair', 'cleanup-preview', 'cleanup',
                                         'plan-windows', 'plan-dry-windows', 'shrink-offline-ext4', 'probe',
                                         'chain-fetch', 'chain-plan', 'chain-shrink', 'chain-stage',
                                         'chain-boot', 'chain-inspect'])
    parser.add_argument('--vm-identity', required=True)
    parser.add_argument('--media-port', type=int, default=8765)
    parser.add_argument('--distro')
    parser.add_argument('--iso-name')
    parser.add_argument('--size', default='30G')
    parser.add_argument('--seed-url')
    args = parser.parse_args()
    if not 1024 <= args.media_port <= 65535:
        raise ValueError('Invalid private media port')
    incumbent = 'kubuntu' if args.step in ('plan-windows', 'plan-dry-windows', 'probe') else 'fedora'
    disk, table = guarded_disk(args.vm_identity, incumbent)
    if args.step == 'prepare':
        result = prepare(args.vm_identity, disk, table)
        print(json.dumps(result))
        return
    if args.step.startswith('chain-'):
        # Breadth chain: one independent plan/state per distro, ISO fetched from the
        # host's verified cache, install driven by the installer's own unattended seed.
        if not args.distro or not re.fullmatch(r'[a-z0-9-]{2,32}', args.distro):
            raise ValueError('A safe distro id is required')
        if not args.iso_name or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,120}\.iso', args.iso_name):
            raise ValueError('A safe ISO name is required')
        ensure_lab_media()
        engine = Path(__file__).resolve().parents[2] / 'bin/usbless-dualboot'
        folder = MEDIA / 'chain'
        folder.mkdir(exist_ok=True)
        plan = folder / (args.distro + '-plan.json')
        state = folder / (args.distro + '-state')
        env = dict(os.environ, USBDB_CONFIG=str(plan), USBDB_STATE_DIR=str(state))
        iso = Path('/var/tmp') / args.iso_name
        if args.step == 'chain-fetch':
            if iso.exists() and iso.stat().st_size > 0:
                result = dict(step=args.step, iso=str(iso), bytes=iso.stat().st_size, reused=True)
                print(json.dumps(result)); return
            partial = iso.with_suffix('.iso.part')
            run('curl', '--fail', '--location', '--continue-at', '-', '--output', partial,
                f'http://10.0.2.2:{args.media_port}/iso/{args.iso_name}')
            partial.rename(iso)
            result = dict(step=args.step, iso=str(iso), bytes=iso.stat().st_size)
            print(json.dumps(result)); return
        if not iso.is_file():
            raise ValueError('The distro media was not fetched into this guest')
        if args.step == 'chain-plan':
            output = run_both('bash', engine, 'plan', '--add', 'linux', '--iso', iso,
                              '--linux-new-size', args.size, '--installer-size', '12G', '--write', env=env)
            if args.seed_url:
                # Lab-only boot parameters: the installer runs from its own
                # unattended seed instead of interactive partitioning.
                config = json.loads(plan.read_text())
                params = config['linux_params'] = (f"boot=casper iso-scan/filename=/{args.iso_name} "
                                                  f"autoinstall 'ds=nocloud-net;s={args.seed_url}' ---")
                plan.write_text(json.dumps(config, indent=2) + '\n')
            result = dict(step=args.step, log_text=output[-3000:], config=json.loads(plan.read_text()))
            print(json.dumps(result)); return
        commands = {'chain-shrink': ['shrink'], 'chain-stage': ['stage', '--os', 'linux'],
                    'chain-boot': ['boot', '--installer'], 'chain-inspect': ['status']}
        output = run_both('bash', engine, *commands[args.step], env=env)
        result = dict(step=args.step, log_text=output[-3000:], config=json.loads(plan.read_text()))
        print(json.dumps(result)); return
    if args.step == 'probe':
        engine = Path(__file__).resolve().parents[2] / 'bin/usbless-dualboot'
        output = run('bash', engine, 'probe', '--json')
        result = dict(step='probe', probe=json.loads(output))
        print(json.dumps(result))
        return
    if args.step == 'plan-dry-windows':
        # Read-only: proves which disk the plan selects when a second disk is present.
        ensure_lab_media()
        engine = Path(__file__).resolve().parents[2] / 'bin/usbless-dualboot'
        windows = MEDIA / WINDOWS_NAME
        if not windows.is_file():
            raise ValueError('The Windows media staged for this plan is missing')
        output = run_both('bash', engine, 'plan', '--add', 'windows', '--iso', windows,
                          '--linux-new-size', '30G', '--installer-size', '12G')
        result = dict(step='plan-dry-windows', log_text=output[-4000:])
        print(json.dumps(result))
        return
    if args.step in ('plan-windows', 'shrink-offline-ext4'):
        # Windows-direction steps run from the installed Kubuntu (plan) or from the
        # preserved Fedora incumbent (offline shrink); the plan lives on the shared
        # lab partition so both systems hash the same media and read the same state.
        ensure_lab_media()
        engine = Path(__file__).resolve().parents[2] / 'bin/usbless-dualboot'
        env = dict(os.environ, USBDB_CONFIG=str(MEDIA / 'windows-plan.json'),
                   USBDB_STATE_DIR=str(STATE_WINDOWS))
        if args.step == 'plan-windows':
            windows = ensure_windows_media()
            output = run_both('bash', engine, 'plan', '--add', 'windows', '--iso', windows,
                              '--linux-new-size', '40G', '--installer-size', '12G', '--write', env=env)
        else:
            windows = MEDIA / WINDOWS_NAME
            if not windows.is_file():
                raise ValueError('The Windows media staged for this plan is missing')
            output = run_both('bash', engine, 'shrink', '--offline', '--iso', windows, env=env)
        STATE_WINDOWS.mkdir(parents=True, exist_ok=True)
        (STATE_WINDOWS / (args.step + '.log')).write_text(output + '\n')
        result = dict(step=args.step, log=str(STATE_WINDOWS / (args.step + '.log')), log_text=output[-4000:],
                      config=json.loads((MEDIA / 'windows-plan.json').read_text()))
        print(json.dumps(result))
        return

    report = json.loads((STATE / 'state.json').read_text())
    if not report.get('prepared') or report.get('vm_identity') != args.vm_identity:
        raise ValueError('This clone was not prepared successfully')
    ensure_media(report, table)
    iso = MEDIA / ISO_NAME
    if args.step == 'fetch':
        if not iso.exists():
            partial = iso.with_suffix('.iso.part')
            run('curl', '--fail', '--location', '--continue-at', '-', '--output', partial,
                f'http://10.0.2.2:{args.media_port}/kubuntu.iso')
            with partial.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            if partial.stat().st_size != ISO_BYTES or digest != ISO_SHA256:
                raise ValueError('Kubuntu media does not match the official size/hash')
            partial.rename(iso)
        else:
            with iso.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            if iso.stat().st_size != ISO_BYTES or digest != ISO_SHA256:
                raise ValueError('Existing media differs; never silently replace it')
        result = dict(iso=str(iso), bytes=ISO_BYTES, sha256=digest)
        print(json.dumps(result))
        return

    engine = Path(__file__).resolve().parents[2] / 'bin/usbless-dualboot'
    saved_iso = MEDIA / 'source-media' / ISO_NAME
    if args.step == 'stage' and saved_iso.exists():
        raise ValueError('Previous source-media relocation exists; inspect instead of repeating staging')
    env = dict(os.environ, USBDB_CONFIG=str(MEDIA / 'kubuntu-plan.json'),
               USBDB_STATE_DIR=str(STATE / 'engine'))
    commands = {
        'plan': ['plan', '--add', 'linux', '--iso', str(iso), '--sha256', ISO_SHA256,
                 '--linux-new-size', '22G', '--installer-size', '12G', '--write'],
        'shrink': ['shrink'], 'stage': ['stage', '--os', 'linux'],
        'boot-installer': ['boot', '--installer'],
        'repair-preview': ['repair-carrier', '--iso', str(saved_iso), '--dry-run'],
        'repair': ['repair-carrier', '--iso', str(saved_iso), '--confirm-rebuild-installer'],
        'cleanup-preview': ['cleanup', '--installer-only', '--dry-run'],
        'cleanup': ['cleanup', '--installer-only', '--confirm-both-booted'],
    }
    output = run_both('bash', engine, *commands[args.step], env=env)
    (STATE / (args.step + '.log')).write_text(output + '\n')
    result = dict(step=args.step, log=str(STATE / (args.step + '.log')),
                  config=json.loads((MEDIA / 'kubuntu-plan.json').read_text()))
    if args.step.startswith('cleanup'):
        # The reviewed removal plan is the evidence for this step.
        result['log_text'] = (STATE / (args.step + '.log')).read_text()[-4000:]
    if args.step == 'stage':
        # Casper the carrier must be the only match for iso-scan/filename.
        if result['config'].get('stage_complete') != '1':
            raise ValueError('Staging did not complete; retain the original ISO path')
        saved_iso.parent.mkdir(exist_ok=True)
        iso.rename(saved_iso)
        result['preserved_source_iso'] = str(saved_iso)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
