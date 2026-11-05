#!/usr/bin/env python3
"""Check the Windows boot recipe against a real, already-verified Fedora KDE ISO."""
import argparse
import json
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso', type=Path)
    parser.add_argument('--pwsh', type=Path, default=Path.home() / '.cache/usbless-dualboot/lab-tools/powershell/7.6.9/pwsh')
    args = parser.parse_args()
    iso = args.iso.resolve(strict=True)
    if not iso.is_file():
        raise ValueError('Use a regular ISO file, never a host block device')
    listing = subprocess.check_output(['bsdtar', '-tf', str(iso)], text=True)
    files = set(listing.splitlines())
    required = {'boot/grub2/grub.cfg', 'EFI/BOOT/BOOTX64.EFI', 'LiveOS/squashfs.img'}
    if not required.issubset(files):
        raise ValueError('ISO lacks the files this Fedora recipe needs')
    text = subprocess.check_output(['bsdtar', '-xOf', str(iso), 'boot/grub2/grub.cfg'], text=True)
    kernels = re.findall(r'^\s*linux\s+(?:\(\$root\))?(/\S+)', text, re.M)
    if not kernels or any(path.lstrip('/') not in files for path in kernels):
        raise ValueError('The menu references a kernel absent from the ISO')
    # This executes the actual engine transformation, without mounting or writing a disk.
    code = r'''
$ErrorActionPreference = 'Stop'
. ./platforms/windows/engine/Common.ps1
. ./platforms/windows/engine/Catalog.ps1
. ./platforms/windows/engine/Boot.ps1
$distro = Get-Catalog | Where-Object Id -eq 'fedora-kde'
$original = [Console]::In.ReadToEnd()
$edited = Get-EditedBootConfig $distro $original
if ($edited -notmatch 'root=live:LABEL=USBLINSTALL') { throw 'Missing internal installer label' }
if ($edited -match 'root=live:CDLABEL=' -or $edited -match 'rd\.live\.check') { throw 'Optical-media arguments remain' }
if ($edited -notmatch 'systemd.run=/usr/bin/umount -l /run/initramfs/live') { throw 'Missing installer disk release' }
if ($edited -cne (Get-EditedBootConfig $distro $edited)) { throw 'Boot edits are not idempotent' }
@{ recipe='fedora-kde'; kernel_entries=([regex]::Matches($edited,'(?m)^\s*linux\s+')).Count; idempotent=$true; internal_label=$true } | ConvertTo-Json -Compress
'''
    result = subprocess.run([str(args.pwsh), '-NoLogo', '-NoProfile', '-Command', code],
                            cwd=REPO, input=text, text=True, capture_output=True, check=True)
    report = json.loads(result.stdout)
    report['iso'] = iso.name
    report['iso_files'] = len(files)
    report['evidence'] = 'media and recipe inspection only; no installation claim'
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
