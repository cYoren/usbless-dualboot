#!/usr/bin/env python3
"""Call the allowlisted agent inside a disposable Windows VM over loopback."""
import argparse
import json
from pathlib import Path
import socket


def main():
    root=Path(__file__).resolve().parents[2]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('action',choices=['status','tests','ui','shutdown'])
    parser.add_argument('--seed',type=Path,default=root/'.lab/seeds/windows-base')
    parser.add_argument('--timeout',type=int,default=120)
    args=parser.parse_args()
    config=json.loads((root/'.lab/vms'/args.name/'vm.json').read_text())
    token=json.loads((args.seed/'agent.json').read_text())['token']
    with socket.create_connection(('127.0.0.1',int(config['agent_port'])),timeout=args.timeout) as connection:
        connection.sendall((json.dumps({'action':args.action,'token':token})+'\n').encode())
        stream=connection.makefile('rb')
        response=json.loads(stream.readline())
    print(json.dumps(response,indent=2))
    if not response.get('ok'):
        raise SystemExit(1)


if __name__=='__main__':
    main()
