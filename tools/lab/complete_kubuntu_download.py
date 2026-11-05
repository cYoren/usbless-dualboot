#!/usr/bin/env python3
"""Complete the lab's pinned ISO using disjoint resumable ranges, preserving its prefix.

Stop the previous curl transfer before running this helper. Every range has its
own retained file. Neither interrupted ranges nor completed chunks are discarded.
Only a matching official SHA-256 marks the final media usable.
"""
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import time
import urllib.request

REPO = Path(__file__).resolve().parents[2]
NAME = 'kubuntu-26.10-desktop-amd64.iso'
SIZE = 5141966848
SHA256 = '8160b1d6266dfe1998d183b19713680263c09669f101e0e41cbcf11f50b6f785'
URL = 'https://cdimage.ubuntu.com/kubuntu/releases/26.10/release/' + NAME
CHUNK = 32 * 1024 * 1024


def download_range(folder, start, end):
    target = folder / f'{start}-{end}.part'
    expected = end - start + 1
    for attempt in range(3):
        current = target.stat().st_size if target.exists() else 0
        if current == expected:
            return
        if current > expected:
            raise ValueError('Oversized range retained for inspection: ' + target.name)
        try:
            first = start + current
            request = urllib.request.Request(URL, headers={'Range': f'bytes={first}-{end}'})
            with urllib.request.urlopen(request, timeout=45) as response:
                if response.status != 206 or response.headers.get('Content-Range') != f'bytes {first}-{end}/{SIZE}':
                    raise ValueError('Server did not return the exact requested ISO range')
                with target.open('ab') as output:
                    remaining = expected - current
                    while remaining:
                        data = response.read(min(256 * 1024, remaining))
                        if not data:
                            raise OSError('Truncated ISO range')
                        output.write(data)
                        remaining -= len(data)
                    output.flush()
                    os.fsync(output.fileno())
            return
        except (OSError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(1)


def main():
    cache = REPO / '.lab/cache'
    iso = cache / NAME
    if iso.is_symlink() or (iso.exists() and not iso.is_file()):
        raise ValueError('ISO must be a regular lab file')
    folder = cache / (NAME + '.ranges')
    folder.mkdir(mode=0o700, exist_ok=True)
    with (folder / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = folder / 'manifest.json'
        if manifest.exists():
            state = json.loads(manifest.read_text())
            if state.get('sha256') != SHA256 or state.get('bytes') != SIZE:
                raise ValueError('Previous range manifest differs; inspect it before proceeding')
        else:
            state = dict(url=URL, sha256=SHA256, bytes=SIZE,
                         prefix=iso.stat().st_size if iso.exists() else 0)
            if not 0 <= state['prefix'] <= SIZE:
                raise ValueError('Existing ISO size differs; never overwrite it')
            manifest.write_text(json.dumps(state, indent=2) + '\n')
        if iso.exists() and iso.stat().st_size == SIZE:
            with iso.open('rb') as source:
                if hashlib.file_digest(source, 'sha256').hexdigest() == SHA256:
                    print('Existing complete official ISO verified; no transfer needed.', flush=True)
                    return
            raise ValueError('Complete media hash differs; retain it for inspection')
        if iso.exists() and iso.stat().st_size != state['prefix']:
            raise ValueError('ISO changed outside the saved manifest; inspect before assembling')
        ranges = [(start, min(start + CHUNK, SIZE) - 1)
                  for start in range(state['prefix'], SIZE, CHUNK)]
        print(f'Reusing {state["prefix"]} bytes; fetching {len(ranges)} disjoint ranges.', flush=True)
        failures = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = {pool.submit(download_range, folder, a, b): (a, b) for a, b in ranges}
            for count, future in enumerate(concurrent.futures.as_completed(futures), 1):
                try:
                    future.result()
                except Exception as error:
                    failures.append(str(error))
                if count % 8 == 0 or count == len(ranges):
                    print(f'Ranges finished: {count}/{len(ranges)}; errors: {len(failures)}', flush=True)
        if failures:
            raise RuntimeError('; '.join(failures))
        # Assemble into a separate file so a crash cannot damage the saved prefix.
        assembled = folder / 'assembled.iso'
        if assembled.exists():
            raise ValueError('Previous assembly remains; inspect it before repeating assembly')
        with assembled.open('xb') as output:
            if iso.exists():
                with iso.open('rb') as source:
                    shutil.copyfileobj(source, output)
            for start, end in ranges:
                with (folder / f'{start}-{end}.part').open('rb') as source:
                    shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
        with assembled.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        if assembled.stat().st_size != SIZE or digest != SHA256:
            raise ValueError('Assembled ISO differs from the signed publisher hash; keep all evidence')
        # Preserve the original downloaded prefix alongside the reusable segments.
        if iso.exists():
            iso.rename(folder / 'original-prefix.iso.part')
        assembled.rename(iso)
        print(json.dumps(dict(verified=True, iso=str(iso), bytes=SIZE, sha256=digest)), flush=True)


if __name__ == '__main__':
    main()
