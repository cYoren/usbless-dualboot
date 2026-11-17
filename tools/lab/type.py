#!/usr/bin/env python3
"""Type one command into the disposable lab VM and screenshot the result.

The lab password is only sent when sudo actually prompts, so it never lands in a
shell prompt or a screenshot. Used to drive the breadth chain by hand; the
allowlisted guest agent remains the only automation path that returns data.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vm', REPO / 'tools/lab/vm.py')
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


def main():
    name = sys.argv[1]
    command = sys.argv[2]
    wait = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0
    folder = REPO / '.lab/vms' / name
    secret = json.loads((REPO / '.lab/seeds/windows-base/credentials.json').read_text())
    vm.type_text(folder, command, 'us')
    vm.send_keys(folder, ['ret'])
    time.sleep(min(wait, 25))
    # Only answer a real prompt: typing the password blindly echoes it into the tty.
    for _ in range(4):
        vm.request(folder / 'qmp.sock', 'screendump', {'filename': str(folder / 'screen.ppm')})
        # Only the last screenful can hold a live prompt; scrollback would match
        # an old "Password:" line and echo the password into the tty.
        subprocess.run(['magick', str(folder / 'screen.ppm'), '-crop', '1280x200+0+600',
                        str(folder / 'prompt.png')], check=True, capture_output=True)
        text = subprocess.run(['tesseract', str(folder / 'prompt.png'), '-', '--psm', '6'],
                              capture_output=True, text=True).stdout
        if 'assword' in text:
            vm.type_text(folder, secret['password'], 'us')
            vm.send_keys(folder, ['ret'])
            time.sleep(wait)
            break
        time.sleep(1.5)
    vm.request(folder / 'qmp.sock', 'screendump', {'filename': str(folder / 'screen.ppm')})
    print('screenshot updated')


if __name__ == '__main__':
    main()
