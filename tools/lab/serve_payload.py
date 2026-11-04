#!/usr/bin/env python3
"""Serve only nonsecret lab update files on host loopback; never expose the seed."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import io
import tarfile

REPO = Path(__file__).resolve().parents[2]


def engine_bundle():
    output = io.BytesIO()
    paths = [REPO / 'bin/usbless-dualboot', REPO / 'tools/lab/case-linux-ext4.sh',
             REPO / 'tools/lab/case-linux-cleanup.sh',
             *sorted((REPO / 'lib').glob('*.sh'))]
    with tarfile.open(fileobj=output, mode='w') as archive:
        for file in paths:
            if not file.is_file() or file.is_symlink():
                raise ValueError('Engine bundle accepts regular source files only')
            info = archive.gettarinfo(str(file), arcname=file.relative_to(REPO).as_posix())
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            with file.open('rb') as source:
                archive.addfile(info, source)
    return output.getvalue()


def update_script(files, port):
    """Pin every incoming script/archive before running the existing bootstrap."""
    lines = ["$ErrorActionPreference = 'Stop'",
             "$ProgressPreference = 'SilentlyContinue'",
             "$pc = Get-CimInstance Win32_ComputerSystem",
             "if ($pc.Manufacturer -ne 'USBlessLab' -or $pc.Model -ne 'DisposableVM') { throw 'Not a disposable VM' }",
             "$dir = Join-Path $env:ProgramData 'USBlessLab\\incoming'",
             "New-Item -ItemType Directory -Path $dir -Force | Out-Null"]
    hashes = {}
    for route, file in files.items():
        with file.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        hashes[route] = digest
        name = route.lstrip('/')
        lines += [f"$file = Join-Path $dir '{name}'",
                  "if (Test-Path -LiteralPath $file) {",
                  "    $oldHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash",
                  f"    if ($oldHash -ne '{digest}') {{",
                  "        $saved = $file + '.saved-' + $oldHash",
                  "        if (Test-Path -LiteralPath $saved) { throw 'Previous incoming file already archived; inspect it before retrying' }",
                  "        Move-Item -LiteralPath $file -Destination $saved",
                  "    }",
                  "}",
                  f"if (-not (Test-Path -LiteralPath $file)) {{ Invoke-WebRequest 'http://10.0.2.2:{port}{route}' -OutFile $file -UseBasicParsing }}",
                  f"if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne '{digest}') {{ throw 'Incoming {name} checksum differs' }}"]
    lines.append("& (Join-Path $dir 'bootstrap.ps1') -PayloadPath (Join-Path $dir 'payload.zip') "
                 "-AgentPath (Join-Path $dir 'agent.ps1') "
                 f"-ExpectedPayloadSha256 '{hashes['/payload.zip']}' -ExpectedAgentSha256 '{hashes['/agent.ps1']}'")
    return ('\r\n'.join(lines) + '\r\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Use an unprivileged TCP port')
    files = {'/payload.zip': REPO / '.lab/seeds/windows-base/payload.zip',
             '/bootstrap.ps1': REPO / 'tools/lab/windows-bootstrap.ps1',
             '/agent.ps1': REPO / 'tools/lab/guest-agent.ps1'}
    for file in files.values():
        if not file.is_file():
            raise ValueError('Build the payload first; a required update file is missing')
    script = update_script(files, args.port)
    # Linux inspection is downloaded separately and never receives the Windows seed.
    files['/linux-agent.py'] = REPO / 'tools/lab/linux-agent.py'
    with files['/linux-agent.py'].open('rb') as source:
        linux_hash = hashlib.file_digest(source, 'sha256').hexdigest()
    linux_script = ('set -euo pipefail\n'
                    'agent=$(mktemp --suffix=.py)\n'
                    f'curl -fsS http://10.0.2.2:{args.port}/linux-agent.py -o "$agent"\n'
                    f'printf "%s  %s\\n" "{linux_hash}" "$agent" | sha256sum -c -\n'
                    'sudo unshare --mount --propagation private python3 "$agent"\n').encode()
    engine = engine_bundle()
    engine_hash = hashlib.sha256(engine).hexdigest().encode()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ['/resume.ps1', '/linux.sh', '/engine.tar', '/engine.sha256']:
                data = {'/resume.ps1': script, '/linux.sh': linux_script,
                        '/engine.tar': engine, '/engine.sha256': engine_hash}[self.path]
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif self.path in files:
                file = files[self.path]
                self.send_response(200)
                self.send_header('Content-Length', str(file.stat().st_size))
                self.end_headers()
                with file.open('rb') as source:
                    shutil.copyfileobj(source, self.wfile)
            else:
                self.send_error(404)

    with ThreadingHTTPServer(('127.0.0.1', args.port), Handler) as server:
        print(f'Nonsecret update files at 127.0.0.1:{args.port}; seed credentials are not served.', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
