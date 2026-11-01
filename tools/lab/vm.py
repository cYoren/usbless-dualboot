#!/usr/bin/env python3
"""Disposable, file-backed UEFI/KVM lab. Never accepts a host block device."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
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
    request(folder/'qmp.sock','send-key',{'keys':[{'type':'qcode','data':key} for key in keys],'hold-time':10})


def type_text(folder, text, layout):
    plain={ ' ':'spc','.':'dot',',':'comma','-':'minus','=':'equal','/':'slash','\\':'backslash',
            ';':'semicolon',"'":'apostrophe','[':'bracket_left',']':'bracket_right','`':'grave' }
    shifted={':':'semicolon','>':'dot','<':'comma','_':'minus','+':'equal','"':'apostrophe',
              '(':'9',')':'0','&':'7','|':'backslash','!':'1','?':'slash'}
    german={':':['shift','dot'],'\\':['alt_r','minus'],'-':['slash'],'/':['shift','7'],
            '>':['shift','less'],'<':['less'],';':['shift','comma'],'_':['shift','slash']}
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
        send_keys(folder,keys)
        time.sleep(.025)


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
    code = regular_file(firmware / "OVMF_CODE.4m.fd")
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
        except OSError:
            monitor.unlink()
    argv = ["-name", "usbless-lab-" + args.name, "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", "2",
            "-smbios", "type=1,manufacturer=USBlessLab,product=DisposableVM,serial=" + config.get('uuid','firmware-smoke'),
            "-m", str(config["memory_mib"]), "-display", "none", "-vga", "std",
            "-L", str(TOOLS / "usr/share/qemu"),
            "-drive", "if=pflash,format=raw,readonly=on,file=" + str(regular_file(config["firmware"])),
            "-drive", "if=pflash,format=raw,file=" + str(regular_file(folder / "OVMF_VARS.fd")),
            "-drive", "if=none,id=os,format=qcow2,file=" + str(disk),
            "-device", "ide-hd,drive=os,bus=ide.0,serial=USBDBLABSYSTEM",
            "-qmp", "unix:" + str(monitor) + ",server=on,wait=off",
            "-serial", "file:" + str(folder / "serial.log"), "-no-reboot"]
    # Installation naturally restarts several times; -no-reboot is only useful for
    # firmware smoke cases and must not stop a Windows/Linux unattended install.
    if config.get("iso"):
        argv.remove("-no-reboot")
        argv += ["-drive", "if=none,id=installer,format=raw,media=cdrom,readonly=on,file=" + str(regular_file(config["iso"])),
                 "-device", "ide-cd,drive=installer,bus=ide.1", "-boot", "order=d,once=d,menu=on"]
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
    start_parser = sub.add_parser("start")
    start_parser.add_argument("name")
    start_parser.add_argument("--offline", action="store_true")
    for action in ["status", "screenshot", "powerdown", "quit", "boot-media"]:
        sub.add_parser(action).add_argument("name")
    key_parser=sub.add_parser('key')
    key_parser.add_argument('name')
    key_parser.add_argument('combination')
    text_parser=sub.add_parser('type')
    text_parser.add_argument('name')
    text_parser.add_argument('text')
    text_parser.add_argument('--layout',choices=['us','de'],default='us')
    text_parser.add_argument('--enter',action='store_true')
    args = parser.parse_args()
    folder = directory(args.name, args.lab)
    if args.action == "create":
        create(args, folder)
    elif args.action == "start":
        start(args, folder)
    elif args.action == 'key':
        if not re.fullmatch(r'[a-z0-9_-]+',args.combination):
            raise ValueError('Invalid VM key combination')
        send_keys(folder,args.combination.split('-'))
    elif args.action == 'type':
        type_text(folder,args.text,args.layout)
        if args.enter: send_keys(folder,['ret'])
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


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("error:", error, file=sys.stderr)
        raise SystemExit(1)
