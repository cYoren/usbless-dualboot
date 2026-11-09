#!/usr/bin/env python3
"""Call the allowlisted agent inside a disposable Windows VM over loopback."""
import argparse
import json
from pathlib import Path
import socket

from vm import directory


def main():
    root=Path(__file__).resolve().parents[2]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('action',choices=['status','inspect','inspect-live','tests','ui','shutdown','reboot','boot-windows','boot-entry','test-ext4','test-cleanup','test-repair','linux-kubuntu','plan-kde','prepare-kde','cleanup-kde'])
    parser.add_argument('--seed',type=Path,default=root/'.lab/seeds/windows-base')
    parser.add_argument('--timeout',type=int,default=120)
    parser.add_argument('--media-port',type=int,default=8765)
    parser.add_argument('--sentinel')
    parser.add_argument('--plan-id')
    parser.add_argument('--source-sha256')
    parser.add_argument('--encrypted',action='store_true')
    parser.add_argument('--entry')
    parser.add_argument('--lab-step',choices=['prepare','fetch','plan','shrink','stage','boot-installer','restore',
                                             'cleanup-preview','cleanup','repair-preview','repair',
                                             'plan-windows','plan-dry-windows','shrink-offline-ext4','probe'])
    args=parser.parse_args()
    folder=directory(args.name,root/'.lab')
    config=json.loads((folder/'vm.json').read_text())
    if config.get('disposable') is not True:
        raise ValueError('VM is not marked disposable')
    if not 1 <= args.timeout <= 3600:
        raise ValueError('Timeout must be between 1 and 3600 seconds')
    token=json.loads((args.seed/'agent.json').read_text())['token']
    with socket.create_connection(('127.0.0.1',int(config['agent_port'])),timeout=args.timeout) as connection:
        connection.sendall((json.dumps({'action':args.action,'token':token,'media_port':args.media_port,
                                       'sentinel':args.sentinel,'plan_id':args.plan_id,'entry':args.entry,
                                       'source_sha256':args.source_sha256,'encrypted':args.encrypted,
                                       'lab_step':args.lab_step,'vm_identity':config.get('uuid'),
                                       'vm_role':config.get('role')})+'\n').encode())
        stream=connection.makefile('rb')
        response=json.loads(stream.readline())
    print(json.dumps(response,indent=2))
    if not response.get('ok'):
        raise SystemExit(1)


if __name__=='__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(json.dumps({'ok':False,'error':str(error)}))
        raise SystemExit(1)
