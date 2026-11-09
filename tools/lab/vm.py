#!/usr/bin/env python3
"""Disposable, file-backed UEFI/KVM lab. Never accepts a host block device."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
TOOLS = Path.home() / ".cache/usbless-dualboot/lab-tools/root"


def environment():
    return dict(os.environ, LD_LIBRARY_PATH=str(TOOLS / "usr/lib")+":"+str(TOOLS / "usr/lib/swtpm"),
                QEMU_MODULE_DIR=str(TOOLS / "usr/lib/qemu"))


def command(name, args):
    return subprocess.run([str(TOOLS / "usr/bin" / name), *map(str, args)],
                          env=environment(), text=True, capture_output=True, check=True)


def regular_file(path):
    resolved = Path(path).resolve(strict=True)
    if any(character in str(resolved) for character in [',','\n','\r']):
        raise ValueError("Image paths cannot contain QEMU option separators")
    if not resolved.is_file() or str(resolved).startswith("/dev/"):
        raise ValueError("Only regular image files are allowed; host block devices are forbidden")
    return resolved


def stop_tpm(folder):
    """Stop only TPM helpers bound to this VM's exact private control path."""
    executable = os.fsencode(TOOLS / 'usr/bin/swtpm')
    control = os.fsencode('type=unixio,path=' + str(folder / 'tpm.sock'))
    for entry in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            arguments = entry.read_bytes().split(b'\0')
            if arguments[0] == executable and control in arguments:
                os.kill(int(entry.parent.name), signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue


def validate_disk_chain(disk, folder):
    """Snapshots may only read regular backing files in this same private VM."""
    layers = json.loads(command('qemu-img', ['info', '--backing-chain', '--output=json', disk]).stdout)
    for layer in layers:
        path = Path(layer['filename'])
        if not path.is_absolute():
            path = disk.parent / path
        resolved = regular_file(path)
        if resolved.parent != folder.resolve():
            raise ValueError('Backing disks must remain inside their own private VM directory')


def directory(name, lab):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", name):
        raise ValueError("VM name must contain only lowercase letters, digits and hyphens")
    root = lab.resolve()
    if any(character in str(root) for character in [',','\n','\r']):
        raise ValueError("Lab paths cannot contain QEMU option separators")
    if not (root.is_relative_to(Path.home()) or root.is_relative_to(Path('/tmp'))):
        raise ValueError("The lab must be under the user's home directory or /tmp")
    destination = root / "vms" / name
    if destination.is_symlink():
        raise ValueError("VM directories cannot be symbolic links")
    return destination


def request(path, execute, arguments=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(8)
        connection.connect(str(path))
        stream = connection.makefile("rwb", buffering=0)
        greeting = json.loads(stream.readline())
        if "QMP" not in greeting:
            raise RuntimeError("Invalid QMP greeting")
        for operation, values in [("qmp_capabilities", {}), (execute, arguments or {})]:
            stream.write((json.dumps({"execute": operation, "arguments": values}) + "\n").encode())
            while True:
                result = json.loads(stream.readline())
                if "error" in result:
                    raise RuntimeError(str(result["error"]))
                if "return" in result:
                    break
        return result["return"]


def send_keys(folder, keys):
    monitor = folder / 'qmp.sock'
    request(monitor, 'input-send-event', {'events': [
        {'type': 'key', 'data': {'down': True, 'key': {'type': 'qcode', 'data': key}}}
        for key in keys]})
    try:
        time.sleep(.05)
    finally:
        # Explicit key-up avoids timer-based modifiers remaining pressed in busy guests.
        request(monitor, 'input-send-event', {'events': [
            {'type': 'key', 'data': {'down': False, 'key': {'type': 'qcode', 'data': key}}}
            for key in reversed(keys)]})
    time.sleep(.025)


def click_point(folder, x, y):
    monitor = folder / 'qmp.sock'
    screen = folder / 'screen.ppm'
    request(monitor, 'screendump', {'filename': str(screen)})
    with screen.open('rb') as capture:
        header = capture.read(128).split()
    if len(header) < 4 or header[0] != b'P6':
        raise ValueError('Unexpected VM screenshot format')
    width, height = int(header[1]), int(header[2])
    if width < 2 or height < 2 or not (0 <= x < width and 0 <= y < height):
        raise ValueError('Click must be inside the current VM screenshot')
    if not any(mouse.get('current') and mouse.get('absolute') for mouse in request(monitor, 'query-mice')):
        raise ValueError('The VM needs an active absolute pointer for screen coordinates')
    request(monitor, 'input-send-event', {'events': [
        {'type': 'abs', 'data': {'axis': 'x', 'value': round(x / (width - 1) * 32767)}},
        {'type': 'abs', 'data': {'axis': 'y', 'value': round(y / (height - 1) * 32767)}}]})
    # Allow the guest pointer to reach the field before its button event arrives.
    time.sleep(.15)
    request(monitor, 'input-send-event', {'events': [{'type': 'btn', 'data': {'down': True, 'button': 'left'}}]})
    time.sleep(.1)
    request(monitor, 'input-send-event', {'events': [{'type': 'btn', 'data': {'down': False, 'button': 'left'}}]})


def type_text(folder, text, layout):
    plain={ ' ':'spc','.':'dot',',':'comma','-':'minus','=':'equal','/':'slash','\\':'backslash',
            ';':'semicolon',"'":'apostrophe','[':'bracket_left',']':'bracket_right','`':'grave_accent' }
    shifted={':':'semicolon','>':'dot','<':'comma','_':'minus','+':'equal','"':'apostrophe',
              '(':'9',')':'0','&':'7','|':'backslash','!':'1','?':'slash',
              '%':'5','*':'8','$':'4','#':'3','@':'2','^':'6','~':'grave_accent'}
    german={':':['shift','dot'],'\\':['alt_r','minus'],'-':['slash'],'/':['shift','7'],
            '>':['shift','less'],'<':['less'],';':['shift','comma'],'_':['shift','slash'],
            '*':['shift','bracket_right'],'@':['alt_r','q'],'|':['alt_r','less'],
            '(':[ 'shift','8'],')':['shift','9'],'&':['shift','6'],'"':['shift','2'],
            '=':['shift','0'],'?':['shift','minus'],'+':['bracket_right'],
            '~':['alt_r','bracket_right']}
    sequences = []
    for character in text:
        if layout=='de' and character in german:
            keys=german[character]
        elif character.isascii() and character.isalnum():
            letter=character.lower()
            if layout=='de' and letter in 'yz': letter='z' if letter=='y' else 'y'
            keys=(['shift'] if character.isupper() else [])+[letter]
        elif character in shifted:
            keys=['shift',shifted[character]]
        elif character in plain:
            keys=[plain[character]]
        else:
            raise ValueError('Unsupported keyboard character in VM command')
        sequences.append(keys)
    # Reject an unsupported command before leaving half of it in the guest.
    for keys in sequences:
        send_keys(folder,keys)
        # Busy graphical guests need time to consume key-up before the next key.
        time.sleep(.2)


def create(args, folder):
    folder.mkdir(parents=True, exist_ok=True)
    config = folder / "vm.json"
    if config.exists() or (folder / "system.qcow2").exists():
        raise ValueError("VM already exists; existing disks are never overwritten")
    iso = str(regular_file(args.iso)) if args.iso else None
    seed = str(regular_file(args.seed)) if args.seed else None
    if not re.fullmatch(r"[1-9][0-9]{0,3}G", args.size):
        raise ValueError("Disk size must be a positive GiB quantity such as 128G")
    if not 256 <= args.memory <= 8192:
        raise ValueError("Guest memory must be between 256 and 8192 MiB")
    firmware = TOOLS / "usr/share/edk2/x64"
    code_name = 'OVMF_CODE.secboot.4m.fd' if args.secure_boot_capable else 'OVMF_CODE.4m.fd'
    code = regular_file(firmware / code_name)
    variables = regular_file(firmware / "OVMF_VARS.4m.fd")
    shutil.copyfile(variables, folder / "OVMF_VARS.fd")
    command("qemu-img", ["create", "-f", "qcow2", folder / "system.qcow2", args.size])
    data = {"format": 1, "name": args.name, "memory_mib": args.memory, "iso": iso,
            "seed": seed, "firmware": str(code), "tpm": args.tpm,
            "created_at": int(time.time()), "disposable": True, "uuid":str(uuid.uuid4())}
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1',0))
        data['agent_port']=reservation.getsockname()[1]
    config.write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps({"created": str(folder), "disk": str(folder / "system.qcow2")}))


def add_disk(args, folder):
    """Create one file-backed data disk for a second-disk case.

    Registered in vm.json and only ever named by file, so the guest sees an extra
    disk while the host exposes nothing but a regular file.
    """
    config_path = folder / 'vm.json'
    config = json.loads(config_path.read_text())
    if config.get('disposable') is not True:
        raise ValueError('VM is not marked disposable')
    if not re.fullmatch(r'[A-Z0-9]{1,20}', args.serial):
        raise ValueError('Data disk serial must be uppercase letters and digits')
    if not re.fullmatch(r'[1-9][0-9]{0,3}G', args.size):
        raise ValueError('Data disk size must be a GiB quantity')
    if any(disk.get('serial') == args.serial for disk in config.get('extra_disks', [])):
        raise ValueError('A data disk with that serial already exists')
    name = 'data-' + args.serial.lower() + '.qcow2'
    target = folder / name
    if target.exists():
        raise ValueError('Data disk file already exists; inspect instead of overwriting')
    command('qemu-img', ['create', '-f', 'qcow2', target, args.size])
    config.setdefault('extra_disks', []).append({'file': name, 'serial': args.serial, 'size': args.size})
    config_path.write_text(json.dumps(config, indent=2) + '\n')
    print(json.dumps({'data_disk': str(target), 'serial': args.serial, 'size': args.size}))


def start(args, folder):
    config = json.loads((folder / "vm.json").read_text())
    if config.get("disposable") is not True:
        raise ValueError("VM is not marked disposable")
    disk = regular_file(folder / "system.qcow2")
    if disk.parent != folder.resolve():
        raise ValueError("The VM disk must remain inside its own directory")
    monitor = folder / "qmp.sock"
    if monitor.exists():
        try:
            return print(json.dumps(request(monitor, "query-status")))
        except (FileNotFoundError, ConnectionRefusedError):
            monitor.unlink()
    pid_file = folder / 'qemu.pid'
    if pid_file.exists():
        pid = pid_file.read_text().strip()
        if pid.isdigit():
            try:
                arguments = Path('/proc', pid, 'cmdline').read_bytes().split(b'\0')
            except FileNotFoundError:
                arguments = []
            disk_option = os.fsencode('file=' + str(disk))
            if arguments and arguments[0] == os.fsencode(TOOLS / 'usr/bin/qemu-system-x86_64') and any(
                    disk_option in argument.split(b',') for argument in arguments):
                raise RuntimeError('The VM is still running without a reachable monitor; refusing a second start')
    # QEMU can exit while its TPM helper remains alive. Never unlink a live
    # helper's socket and spawn another process over the same persistent state.
    stop_tpm(folder)
    validate_disk_chain(disk, folder)
    argv = ["-name", "usbless-lab-" + args.name, "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", "2",
            "-smbios", "type=1,manufacturer=USBlessLab,product=DisposableVM,serial=" + config.get('uuid','firmware-smoke'),
            "-m", str(config["memory_mib"]), "-display", "none", "-vga", "std",
            "-L", str(TOOLS / "usr/share/qemu"),
            "-drive", "if=pflash,format=raw,readonly=on,file=" + str(regular_file(config["firmware"])),
            "-drive", "if=pflash,format=raw,file=" + str(regular_file(folder / "OVMF_VARS.fd")),
            "-drive", "if=none,id=os,format=qcow2,file=" + str(disk),
            "-device", "ide-hd,drive=os,bus=ide.0,serial=USBDBLABSYSTEM",
            "-qmp", "unix:" + str(monitor) + ",server=on,wait=off",
            "-serial", "file:" + str(folder / "serial.log")]
    if '.secboot.' in Path(config['firmware']).name:
        argv[argv.index('-machine') + 1] += ',smm=on'
        argv += ['-global', 'driver=cfi.pflash01,property=secure,value=on']
    # Both installation and testing naturally restart the guest several times.
    # Do not use -no-reboot even when booting an already installed system.
    for index, extra in enumerate(config.get('extra_disks', [])):
        # Additional data disks stay inside this private VM folder and are never
        # host block devices, so a two-disk case cannot reach the host.
        data = regular_file(folder / extra['file'])
        if data.parent != folder.resolve():
            raise ValueError('Data disks must remain inside their own VM directory')
        serial = extra.get('serial', 'USBDBLABDATA')
        if not re.fullmatch(r'[A-Z0-9]{1,20}', serial):
            raise ValueError('Data disk serial must be uppercase letters and digits')
        argv += ["-drive", f"if=none,id=extra{index},format=qcow2,file=" + str(data),
                 "-device", f"ide-hd,drive=extra{index},bus=ide.{index + 1},serial=" + serial]
    extra = len(config.get('extra_disks', []))
    if config.get("iso"):
        argv += ["-drive", "if=none,id=installer,format=raw,media=cdrom,readonly=on,file=" + str(regular_file(config["iso"])),
                 "-device", "ide-cd,drive=installer,bus=ide." + str(extra + 1), "-boot", "order=d,once=d,menu=on"]
    if config.get("seed"):
        argv += ["-device", "qemu-xhci,id=usb", "-drive", "if=none,id=seed,format=raw,file=" + str(regular_file(config["seed"])),
                 "-device", "usb-storage,drive=seed,removable=on"]
    if args.offline:
        argv += ["-nic", "none"]
    else:
        port=int(config.get('agent_port',47770))
        if not 1024 <= port <= 65535:
            raise ValueError('Invalid loopback agent port')
        argv += ["-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:"+str(port)+"-:4777", "-device", "e1000e,netdev=n0"]
    if config.get("tpm"):
        state = folder / "tpm"
        state.mkdir(exist_ok=True)
        control = folder / "tpm.sock"
        if control.exists():
            control.unlink()
        with (folder / "swtpm.log").open("ab") as log:
            process = subprocess.Popen([str(TOOLS / "usr/bin/swtpm"), "socket", "--tpm2",
                        "--tpmstate", "dir=" + str(state), "--ctrl", "type=unixio,path=" + str(control),
                        "--flags", "not-need-init"], env=environment(), stdout=log, stderr=log, start_new_session=True)
        (folder / "swtpm.pid").write_text(str(process.pid))
        for _ in range(30):
            if control.exists():
                break
            if process.poll() is not None:
                raise RuntimeError("Software TPM failed; see swtpm.log")
            time.sleep(.1)
        argv += ["-chardev", "socket,id=chrtpm,path=" + str(control), "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                 "-device", "tpm-tis,tpmdev=tpm0"]
    with (folder / "qemu.log").open("ab") as log:
        process = subprocess.Popen([str(TOOLS / "usr/bin/qemu-system-x86_64"), *argv], env=environment(),
                                   stdout=log, stderr=log, start_new_session=True)
    (folder / "qemu.pid").write_text(str(process.pid))
    (folder / "command.json").write_text(json.dumps(argv, indent=2) + "\n")
    for _ in range(50):
        if process.poll() is not None:
            raise RuntimeError("QEMU stopped; inspect " + str(folder / "qemu.log"))
        if monitor.exists():
            print(json.dumps({"pid": process.pid, "status": request(monitor, "query-status")}))
            return
        time.sleep(.1)
    raise RuntimeError("QEMU did not expose its monitor in time")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab", type=Path, default=REPO / ".lab")
    sub = parser.add_subparsers(dest="action", required=True)
    create_parser = sub.add_parser("create")
    create_parser.add_argument("name")
    create_parser.add_argument("--size", default="128G")
    create_parser.add_argument("--memory", type=int, default=4096)
    create_parser.add_argument("--iso")
    create_parser.add_argument("--seed")
    create_parser.add_argument("--tpm", action="store_true")
    create_parser.add_argument('--secure-boot-capable', action='store_true',
                               help='Use Secure Boot-capable firmware (does not enroll keys)')
    disk_parser = sub.add_parser("add-disk")
    disk_parser.add_argument("name")
    disk_parser.add_argument("--size", default="32G")
    disk_parser.add_argument("--serial", default="USBDBLABDATA")
    start_parser = sub.add_parser("start")
    start_parser.add_argument("name")
    start_parser.add_argument("--offline", action="store_true")
    for action in ["status", "screenshot", "powerdown", "quit", "boot-media"]:
        sub.add_parser(action).add_argument("name")
    key_parser=sub.add_parser('key')
    key_parser.add_argument('name')
    key_parser.add_argument('combination')
    click_parser = sub.add_parser('click')
    click_parser.add_argument('name')
    click_parser.add_argument('x', type=int)
    click_parser.add_argument('y', type=int)
    text_parser=sub.add_parser('type')
    text_parser.add_argument('name')
    text_parser.add_argument('text')
    text_parser.add_argument('--layout',choices=['us','de'],default='us')
    text_parser.add_argument('--enter',action='store_true')
    link_parser = sub.add_parser('link')
    link_parser.add_argument('name')
    link_parser.add_argument('state', choices=['up', 'down'])
    args = parser.parse_args()
    folder = directory(args.name, args.lab)
    if args.action == "create":
        create(args, folder)
    elif args.action == "start":
        start(args, folder)
    elif args.action == 'add-disk':
        add_disk(args, folder)
    elif args.action == 'key':
        if not re.fullmatch(r'[a-z0-9_-]+',args.combination):
            raise ValueError('Invalid VM key combination')
        send_keys(folder,args.combination.split('-'))
    elif args.action == 'type':
        type_text(folder,args.text,args.layout)
        if args.enter: send_keys(folder,['ret'])
    elif args.action == 'click':
        click_point(folder, args.x, args.y)
    elif args.action == 'link':
        print(json.dumps(request(folder / 'qmp.sock', 'set_link', {'name': 'n0', 'up': args.state == 'up'})))
    elif args.action == 'boot-media':
        # Installation DVDs wait for a key on their first boot. This operates
        # only through this disposable VM's private QMP socket.
        request(folder/'qmp.sock','system_reset')
        for _ in range(24):
            time.sleep(.5)
            request(folder/'qmp.sock','send-key',{'keys':[{'type':'qcode','data':'spc'}]})
        print(json.dumps({'media_boot_requested':True}))
    else:
        operations = {"status": "query-status", "screenshot": "screendump", "powerdown": "system_powerdown", "quit": "quit"}
        values = {"filename": str(folder / "screen.ppm")} if args.action == "screenshot" else {}
        print(json.dumps(request(folder / "qmp.sock", operations[args.action], values)))
        if args.action == 'quit':
            stop_tpm(folder)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("error:", error, file=sys.stderr)
        raise SystemExit(1)
