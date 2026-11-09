#!/usr/bin/env python3
"""Fetch publisher ISO media for the validation matrix, resumably and in parallel.

Only the publisher's own checksum file decides completion. A partial or
mismatched download is never renamed into place and never deleted: it stays as
``*.part`` (resumable) or ``*.rejected-<stamp>`` so a later run can reuse it.
Existing verified media is reused, never re-downloaded (zero-waste rule).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

REPO = Path(__file__).resolve().parents[2]

# listing directory, filename pattern (chosen as the newest match), checksum file
MEDIA = {
    'ubuntu': ('https://releases.ubuntu.com/26.04/', r'^ubuntu-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'ubuntu-server': ('https://releases.ubuntu.com/26.04/', r'^ubuntu-[\d.]+-live-server-amd64\.iso$', 'SHA256SUMS'),
    'kubuntu': ('https://cdimage.ubuntu.com/kubuntu/releases/26.10/release/', r'^kubuntu-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'lubuntu': ('https://cdimage.ubuntu.com/lubuntu/releases/26.04/release/', r'^lubuntu-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'xubuntu': ('https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/', r'^xubuntu-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'ubuntu-budgie': ('https://cdimage.ubuntu.com/ubuntu-budgie/releases/26.04/release/', r'^ubuntu-budgie-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'ubuntucinnamon': ('https://cdimage.ubuntu.com/ubuntucinnamon/releases/26.04/release/', r'^ubuntucinnamon-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'ubuntu-unity': ('https://cdimage.ubuntu.com/ubuntu-unity/releases/26.04/release/', r'^ubuntu-unity-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'edubuntu': ('https://cdimage.ubuntu.com/edubuntu/releases/26.04/release/', r'^edubuntu-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'ubuntustudio': ('https://cdimage.ubuntu.com/ubuntustudio/releases/26.04/release/', r'^ubuntustudio-[\d.]+-desktop-amd64\.iso$', 'SHA256SUMS'),
    'debian-netinst': ('https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/', r'^debian-[\d.]+-amd64-netinst\.iso$', 'SHA256SUMS'),
    'debian': ('https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/', r'^debian-[\d.]+-amd64-DVD-1\.iso$', 'SHA256SUMS'),
    'mint-cinnamon': ('https://mirrors.kernel.org/linuxmint/stable/22.3/', r'^linuxmint-[\d.]+-cinnamon-64bit\.iso$', 'sha256sum.txt'),
    'mint-mate': ('https://mirrors.kernel.org/linuxmint/stable/22.3/', r'^linuxmint-[\d.]+-mate-64bit\.iso$', 'sha256sum.txt'),
    'mint-xfce': ('https://mirrors.kernel.org/linuxmint/stable/22.3/', r'^linuxmint-[\d.]+-xfce-64bit\.iso$', 'sha256sum.txt'),
    'fedora': ('https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/', r'^Fedora-Workstation-Live-[\w.-]+\.iso$', None),
    'fedora-kde': ('https://download.fedoraproject.org/pub/fedora/linux/releases/44/KDE/x86_64/iso/', r'^Fedora-KDE(-Desktop)?-Live-[\w.-]+\.iso$', None),
    'arch': ('https://geo.mirror.pkgbuild.com/iso/latest/', r'^archlinux-[\d.]+-x86_64\.iso$', 'sha256sums.txt'),

};


def listing(url):
    result = subprocess.run(['curl', '-sSL', '--fail', '--max-time', '60', url],
                            capture_output=True, text=True, check=True)
    return [m for m in re.findall(r'href="([^"/?]+)"', result.stdout)]


def key(name):
    # Version digits only: the trailing "amd64" must not outrank a point release.
    version = re.search(r'\d+(?:\.\d+)+', name)
    return [int(part) for part in (version.group(0).split('.') if version else re.findall(r'\d+', name))]


def resolve(entry):
    directory, pattern, sums = MEDIA[entry]
    names = [n for n in listing(directory) if re.match(pattern, n)]
    if not names:
        raise RuntimeError(f'{entry}: no media matched {pattern} at {directory}')
    name = max(names, key=key)
    checksum = sums
    if checksum is None:  # Fedora publishes one signed *-CHECKSUM file beside the images
        candidates = [n for n in listing(directory) if n.endswith('-CHECKSUM')]
        if len(candidates) != 1:
            raise RuntimeError(f'{entry}: expected exactly one CHECKSUM file, found {len(candidates)}')
        checksum = candidates[0]
    return directory, name, checksum


def published(entry, directory, media, checksum):
    text = subprocess.run(['curl', '-sSL', '--fail', '--max-time', '120', directory + checksum],
                          capture_output=True, text=True, check=True).stdout
    # GNU style "<hash>  <name>", BSD/Fedora style "SHA256 (<name>) = <hash>".
    for pattern in (r'^([0-9a-fA-F]{64})\s+\*?' + re.escape(media) + r'$',
                    r'^SHA256 \(' + re.escape(media) + r'\) = ([0-9a-fA-F]{64})$'):
        for line in text.splitlines():
            match = re.match(pattern, line.strip())
            if match:
                return match.group(1).lower()
    raise RuntimeError(f'{entry}: {media} is absent from {directory}{checksum}')


def reject_partial(partial):
    """Quarantine a transfer that completed but failed verification.

    ``--continue-at`` resumes from the existing file, so a corrupt completed
    download can never repair itself; keep the bytes as evidence under a
    distinct name and let the next attempt start from scratch.
    """
    rejected = partial.with_name(partial.name + '.rejected-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()))
    partial.rename(rejected)
    return rejected


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 << 20), b''):
            value.update(block)
    return value.hexdigest()


def fetch(entry, root, retries):
    folder = root / entry
    folder.mkdir(parents=True, exist_ok=True)
    record = folder / 'media.json'
    directory, media, checksum = resolve(entry)
    expected = published(entry, directory, media, checksum)
    target = folder / media
    if target.exists() and (not record.exists() or json.loads(record.read_text()).get('sha256') == expected):
        if digest(target) == expected:
            return {'entry': entry, 'media': str(target), 'sha256': expected, 'state': 'reused'}
        raise RuntimeError(f'{entry}: existing {media} no longer matches the publisher')
    if target.exists():
        raise RuntimeError(f'{entry}: existing {media} differs from the recorded evidence')
    partial = folder / (media + '.part')
    for attempt in range(1, retries + 1):
        completed = subprocess.run(['curl', '-fsSL', '--no-progress-meter', '--retry', '5', '--retry-delay', '5',
                                    '--continue-at', '-', '--output', str(partial), directory + media],
                                   check=False).returncode
        if partial.exists() and digest(partial) == expected:
            partial.rename(target)
            record.write_text(json.dumps({'entry': entry, 'url': directory + media, 'sha256': expected,
                                          'bytes': target.stat().st_size, 'checksum_url': directory + checksum,
                                          'fetched_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())},
                                         indent=2) + '\n')
            return {'entry': entry, 'media': str(target), 'sha256': expected, 'state': 'fetched'}
        if completed == 0 and partial.exists():
            # A transfer that finished but fails verification is corrupt, not
            # resumable: --continue-at would skip the same bad bytes forever.
            rejected = reject_partial(partial)
            return {'entry': entry, 'state': 'rejected', 'rejected': str(rejected),
                    'bytes': rejected.stat().st_size, 'expected_sha256': expected}
        time.sleep(5 * attempt)
    size = partial.stat().st_size if partial.exists() else 0
    return {'entry': entry, 'state': 'incomplete', 'bytes': size, 'expected_sha256': expected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('entries', nargs='*', default=[], help='catalog ids (default: all)')
    parser.add_argument('--cache', type=Path, default=REPO / '.lab/cache/isos')
    parser.add_argument('--jobs', type=int, default=3)
    parser.add_argument('--retries', type=int, default=4)
    args = parser.parse_args()
    entries = args.entries or sorted(MEDIA)
    unknown = [e for e in entries if e not in MEDIA]
    if unknown:
        parser.error('unknown entries: ' + ', '.join(unknown))
    args.cache.mkdir(parents=True, exist_ok=True)
    failures = 0
    with ThreadPoolExecutor(max_workers=max(1, min(args.jobs, len(entries)))) as pool:
        for result in pool.map(lambda e: fetch(e, args.cache, args.retries), entries):
            print(json.dumps(result), flush=True)
            failures += result['state'] != 'fetched' and result['state'] != 'reused'
    return 1 if failures else 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print('error:', error, file=sys.stderr)
        raise SystemExit(1)
