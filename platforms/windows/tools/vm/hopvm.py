#!/usr/bin/env python3
"""Runs a real Windows in QEMU with OVMF and drives it from outside, as a person at the PC would.

Keys and the mouse go in through QEMU, so they reach the elevation prompt and hop's elevated
window alike. Screens come out through screendump. An agent in the VM runs PowerShell for looking
at what happened. Only the standard library, so it runs on a bare GitHub Actions runner.

    hopvm.py build-image --iso windows.iso      install Windows and compress the disk
    hopvm.py run <scenario> ...                 start from the image and run scenarios.py
"""
import argparse
import base64
import http.server
import json
import os
import queue
import shutil
import socket
import socketserver
import struct
import subprocess
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get('HOPVM_WORK', '/mnt/hopvm')
IMAGE = os.path.join(WORK, 'image')
RUN = os.path.join(WORK, 'run')
FILES = os.path.join(WORK, 'files')
OUT = os.environ.get('HOPVM_OUT', os.path.join(WORK, 'out'))
PORT = 8765
OVMF_CODE = '/usr/share/OVMF/OVMF_CODE_4M.secboot.fd'
OVMF_CODE_OFF = '/usr/share/OVMF/OVMF_CODE_4M.fd'
OVMF_VARS = '/usr/share/OVMF/OVMF_VARS_4M.ms.fd'

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash', ':': 'semicolon',
           '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '\n': 'ret', '\t': 'tab', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
         '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent'}


def log(text):
    print(f'[{time.strftime("%H:%M:%S")}] {text}', flush=True)


def run(*argv, **kw):
    log('$ ' + ' '.join(str(a) for a in argv))
    return subprocess.run([str(a) for a in argv], check=True, **kw)


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    return struct.unpack('>II', head[16:24])


class Agents(http.server.BaseHTTPRequestHandler):
    """What the agents in the VM talk to. Files are served from FILES."""
    vm = None
    protocol_version = 'HTTP/1.0'

    def log_message(self, *args):
        pass

    def reply(self, body=b'', code=200):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == '/next':
            who = query['who'][0]
            self.vm.saw_agent(who, query.get('boot', [''])[0])
            boot = query.get('boot', [''])[0]
            try:
                job = self.vm.jobs[who].get(timeout=15)
            except queue.Empty:
                return self.reply()
            # A request left over from before Windows restarted would lose the job.
            if self.vm.agent_boot.get(who) != boot:
                self.vm.jobs[who].put(job)
                return self.reply()
            try:
                self.reply(json.dumps(job).encode())
            except OSError:
                self.vm.jobs[who].put(job)
        elif url.path.startswith('/file/'):
            path = os.path.join(FILES, os.path.basename(url.path))
            if not os.path.isfile(path):
                return self.reply(b'', 404)
            size = os.path.getsize(path)
            self.send_response(200)
            self.send_header('Content-Length', str(size))
            self.end_headers()
            with open(path, 'rb') as f:
                shutil.copyfileobj(f, self.wfile, 1024 * 1024)
        else:
            self.reply(b'', 404)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if url.path == '/result':
            self.vm.results[int(query['id'][0])] = body.decode('utf-8', 'replace').lstrip('﻿')
        elif url.path == '/post':
            # Text from a Linux live system, or anything else that can reach the host.
            name = os.path.basename(query.get('name', ['post'])[0])
            with open(os.path.join(OUT, f'post-{name}.txt'), 'ab') as f:
                f.write(body + b'\n')
            log(f'post {name}: {body[:20000].decode("utf-8", "replace")}')
        else:
            log(f'guest: {body.decode("utf-8", "replace")}')
        self.reply()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass    # an agent gone mid-request, because Windows restarted


class Vm:
    def __init__(self, secure_boot=True, memory_gb=12, cpus=4):
        self.secure_boot = secure_boot
        self.memory_gb = memory_gb
        self.cpus = cpus
        self.qemu = None
        self.swtpm = None
        self.qmp_file = None
        self.qmp_lock = threading.Lock()
        self.shots = 0
        self.jobs = {'user': queue.Queue(), 'system': queue.Queue()}
        self.results = {}
        self.next_id = 1
        self.agent_seen = {}
        self.agent_boot = {}
        self.extra_disks = []
        self.stop_lapse = threading.Event()
        os.makedirs(OUT, exist_ok=True)
        os.makedirs(os.path.join(OUT, 'lapse'), exist_ok=True)
        Agents.vm = self
        self.server = Server(('127.0.0.1', PORT), Agents)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    # --- Starting and stopping ---------------------------------------------------------

    def start_tpm(self, folder):
        os.makedirs(folder, exist_ok=True)
        self.tpm_socket = os.path.join(folder, 'swtpm.sock')
        if os.path.exists(self.tpm_socket):
            os.unlink(self.tpm_socket)
        self.swtpm = subprocess.Popen(['swtpm', 'socket', '--tpmstate', f'dir={folder}', '--tpm2',
                                       '--ctrl', f'type=unixio,path={self.tpm_socket}', '--log', f'file={OUT}/swtpm.log'])
        for _ in range(50):
            if os.path.exists(self.tpm_socket):
                return
            time.sleep(0.2)
        raise RuntimeError('swtpm did not start')

    def start(self, disk, vars_fd, tpm_folder, cds=(), boot_from_cd=False):
        self.start_tpm(tpm_folder)
        self.qmp_path = os.path.join(WORK, 'qmp.sock')
        if os.path.exists(self.qmp_path):
            os.unlink(self.qmp_path)
        code = OVMF_CODE if self.secure_boot else OVMF_CODE_OFF
        argv = ['qemu-system-x86_64', '-name', 'hopvm', '-enable-kvm', '-machine', 'q35,smm=on,accel=kvm',
                '-cpu', 'host,-vmx,-svm,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_frequencies',
                '-smp', str(self.cpus), '-m', f'{self.memory_gb}G',
                '-global', 'driver=cfi.pflash01,property=secure,value=on',
                '-global', 'ICH9-LPC.disable_s3=1', '-global', 'ICH9-LPC.disable_s4=0',
                '-drive', f'if=pflash,format=raw,readonly=on,file={code}',
                '-drive', f'if=pflash,format=raw,file={vars_fd}',
                '-chardev', f'socket,id=chrtpm,path={self.tpm_socket}', '-tpmdev', 'emulator,id=tpm0,chardev=chrtpm', '-device', 'tpm-tis,tpmdev=tpm0',
                '-rtc', 'base=utc,driftfix=slew', '-device', 'VGA,vgamem_mb=64,xres=1280,yres=800',
                '-netdev', 'user,id=n0', '-device', 'e1000e,netdev=n0',
                '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0', '-device', 'usb-tablet,bus=xhci.0',
                # No bootindex on the disk: the firmware has to go by its own BootOrder and BootNext, as a PC does.
                '-drive', f'file={disk},if=none,id=os,format=qcow2,cache=unsafe,discard=unmap,aio=threads',
                '-device', 'nvme,drive=os,serial=HOP0001',
                '-display', 'none', '-serial', f'file:{OUT}/serial.log',
                '-qmp', f'unix:{self.qmp_path},server=on,wait=off']
        for index, path in enumerate(self.extra_disks):
            argv += ['-drive', f'file={path},if=none,id=data{index},format=qcow2,cache=unsafe,discard=unmap,aio=threads',
                     '-device', f'nvme,drive=data{index},serial=HOP100{index}']
        for index, path in enumerate(cds):
            argv += ['-drive', f'file={path},if=none,id=cd{index},media=cdrom,readonly=on',
                     '-device', f'ide-cd,drive=cd{index},bus=ide.{index}' + (f',bootindex={index}' if boot_from_cd else '')]
        log('$ ' + ' '.join(argv))
        self.qemu = subprocess.Popen(argv)
        for _ in range(100):
            if os.path.exists(self.qmp_path):
                break
            time.sleep(0.2)
        sock = socket.socket(socket.AF_UNIX)
        sock.connect(self.qmp_path)
        self.qmp_file = sock.makefile('rw')
        self.qmp_file.readline()
        self.qmp('qmp_capabilities')
        threading.Thread(target=self.lapse, daemon=True).start()

    def running(self):
        return self.qemu is not None and self.qemu.poll() is None

    def stop(self):
        self.stop_lapse.set()
        if self.running():
            self.qemu.terminate()
            try:
                self.qemu.wait(20)
            except subprocess.TimeoutExpired:
                self.qemu.kill()
        if self.swtpm:
            self.swtpm.terminate()

    def lapse(self):
        """A screen a minute whatever else is going on, so a hang can be seen afterwards."""
        count = 0
        while not self.stop_lapse.wait(60):
            if not self.running():
                return
            count += 1
            try:
                self.dump(os.path.join(OUT, 'lapse', f'{count:04}.png'))
            except Exception as ex:
                log(f'lapse: {ex}')

    # --- QEMU ----------------------------------------------------------------------------

    def qmp(self, name, **arguments):
        with self.qmp_lock:
            self.qmp_file.write(json.dumps({'execute': name, 'arguments': arguments}) + '\n')
            self.qmp_file.flush()
            while True:
                line = self.qmp_file.readline()
                if not line:
                    raise RuntimeError('QEMU has gone')
                reply = json.loads(line)
                if 'return' in reply:
                    return reply['return']
                if 'error' in reply:
                    raise RuntimeError(f'{name}: {reply["error"]}')

    def dump(self, path):
        self.qmp('screendump', filename=path, format='png')
        for _ in range(50):
            if os.path.exists(path) and os.path.getsize(path) > 0:
                return
            time.sleep(0.1)

    def shot(self, name):
        """A named screen, for looking at afterwards."""
        self.shots += 1
        path = os.path.join(OUT, f'{self.shots:03}-{name}.png')
        self.dump(path)
        log(f'screen {os.path.basename(path)}')
        return path

    def key(self, *combo, hold=80):
        self.qmp('send-key', keys=[{'type': 'qcode', 'data': k} for k in combo], **{'hold-time': hold})

    def type(self, text, delay=0.12):
        for ch in text:
            if ch.isascii() and ch.isalpha():
                combo = ['shift', ch.lower()] if ch.isupper() else [ch]
            elif ch.isdigit():
                combo = [ch]
            elif ch in SHIFTED:
                combo = ['shift', SHIFTED[ch]]
            elif ch in PLAIN:
                combo = [PLAIN[ch]]
            else:
                raise ValueError(f'no key for {ch!r}')
            # One at a time, or the next arrives while this is held, and Linux sees it repeat for ever.
            self.key(*combo, hold=40)
            time.sleep(delay)

    def screen_size(self):
        path = os.path.join(WORK, 'size.png')
        self.dump(path)
        return png_size(path)

    def move(self, x, y):
        width, height = self.screen_size()
        self.qmp('input-send-event', events=[
            {'type': 'abs', 'data': {'axis': 'x', 'value': int(x * 32767 / (width - 1))}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': int(y * 32767 / (height - 1))}}])

    def button(self, down, which='left'):
        self.qmp('input-send-event', events=[{'type': 'btn', 'data': {'down': down, 'button': which}}])

    def click(self, x, y, which='left'):
        self.move(x, y)
        time.sleep(0.25)
        self.button(True, which)
        time.sleep(0.1)
        self.button(False, which)
        time.sleep(0.3)

    # --- The agents ----------------------------------------------------------------------

    def saw_agent(self, who, boot):
        self.agent_seen[who] = time.time()
        if self.agent_boot.get(who) != boot:
            log(f'agent {who} says Windows started at {boot}')
            self.agent_boot[who] = boot

    def wait_agent(self, who='user', limit=600, not_boot=None):
        """Until the agent has been heard from, on a different start of Windows if not_boot is given."""
        end = time.time() + limit
        while time.time() < end:
            seen = self.agent_seen.get(who, 0)
            if time.time() - seen < 25 and (not_boot is None or self.agent_boot.get(who) != not_boot):
                return self.agent_boot.get(who)
            if not self.running():
                raise RuntimeError('QEMU has gone')
            time.sleep(2)
        raise TimeoutError(f'the {who} agent did not appear within {limit} seconds')

    def ps(self, script, who='user', timeout=300):
        """Runs PowerShell in the VM and returns what it printed."""
        job = self.next_id
        self.next_id += 1
        self.jobs[who].put({'id': job, 'timeout': timeout, 'script': base64.b64encode(script.encode()).decode()})
        end = time.time() + timeout + 60
        while time.time() < end:
            if job in self.results:
                return self.results.pop(job)
            if not self.running():
                raise RuntimeError('QEMU has gone')
            time.sleep(0.5)
        raise TimeoutError(f'no answer to: {script[:80]}')


def make_iso(folder, path):
    run('genisoimage', '-quiet', '-J', '-r', '-V', 'UNATTEND', '-o', path, folder)


def build_image(args):
    """Installs Windows unattended, then compresses what's on the disk into IMAGE."""
    os.makedirs(IMAGE, exist_ok=True)
    os.makedirs(RUN, exist_ok=True)
    os.makedirs(FILES, exist_ok=True)
    answer = os.path.join(WORK, 'unattend')
    os.makedirs(answer, exist_ok=True)
    for name in ('autounattend.xml', 'firstlogon.ps1', 'boot.ps1'):
        shutil.copy(os.path.join(HERE, name), answer)
    unattend = os.path.join(WORK, 'unattend.iso')
    make_iso(answer, unattend)
    disk = os.path.join(RUN, 'install.qcow2')
    vars_fd = os.path.join(RUN, 'install-vars.fd')
    tpm = os.path.join(RUN, 'install-tpm')
    run('qemu-img', 'create', '-f', 'qcow2', disk, '128G')
    shutil.copy(OVMF_VARS, vars_fd)
    vm = Vm(memory_gb=8)
    vm.start(disk, vars_fd, tpm, cds=[args.iso, unattend], boot_from_cd=True)
    # "Press any key to boot from CD or DVD", once. Not for long: Setup's Cancel button comes next.
    for second in range(20):
        vm.key('spc')
        time.sleep(1)
    vm.shot('setup-started')
    end = time.time() + args.limit * 60
    while vm.running():
        if time.time() > end:
            vm.shot('setup-timed-out')
            vm.stop()
            raise SystemExit(f'Windows did not finish installing in {args.limit} minutes')
        time.sleep(10)
    vm.stop()
    log(f'Windows finished installing, code {vm.qemu.returncode}')
    run('qemu-img', 'convert', '-c', '-p', '-O', 'qcow2', '-o', 'compression_type=zstd', disk, os.path.join(IMAGE, 'win.qcow2'))
    shutil.copy(vars_fd, os.path.join(IMAGE, 'vars.fd'))
    shutil.copytree(tpm, os.path.join(IMAGE, 'tpm'), dirs_exist_ok=True, ignore=shutil.ignore_patterns('*.sock'))
    run('du', '-sh', IMAGE)
    run('ls', '-la', IMAGE)


def new_run_disks():
    """A fresh start from the image: a thin copy of its disk, and its firmware settings and TPM."""
    os.makedirs(RUN, exist_ok=True)
    disk = os.path.join(RUN, 'disk.qcow2')
    if os.path.exists(disk):
        os.unlink(disk)
    run('qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', os.path.join(IMAGE, 'win.qcow2'), disk)
    vars_fd = os.path.join(RUN, 'vars.fd')
    shutil.copy(os.path.join(IMAGE, 'vars.fd'), vars_fd)
    tpm = os.path.join(RUN, 'tpm')
    shutil.rmtree(tpm, ignore_errors=True)
    shutil.copytree(os.path.join(IMAGE, 'tpm'), tpm)
    return disk, vars_fd, tpm


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    build = commands.add_parser('build-image')
    build.add_argument('--iso', required=True)
    build.add_argument('--limit', type=int, default=110, help='minutes')
    go = commands.add_parser('run')
    go.add_argument('scenarios', nargs='+')
    go.add_argument('--no-secure-boot', action='store_true')
    args = parser.parse_args()
    if args.command == 'build-image':
        build_image(args)
    else:
        import scenarios
        scenarios.main(args)


if __name__ == '__main__':
    main()
