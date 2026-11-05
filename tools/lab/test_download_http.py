"""Exercise the actual PowerShell HTTP retry policy against a local server."""
import http.server
from pathlib import Path
import subprocess
import threading
import unittest

REPO = Path(__file__).resolve().parents[2]
PWSH = Path.home() / '.cache/usbless-dualboot/lab-tools/powershell/7.6.9/pwsh'


@unittest.skipUnless(PWSH.is_file(), 'cached PowerShell is not installed')
class DownloadHttp(unittest.TestCase):
    def run_response_sequence(self, statuses):
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                index = min(len(requests), len(statuses) - 1)
                requests.append(self.path)
                self.send_response(statuses[index])
                self.end_headers()
                self.wfile.write(b'publisher data')

            def log_message(self, *args):
                pass

        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            code = r'''
. ./platforms/windows/engine/Download.ps1
function Write-Log([string]$Message) { }
function Start-Sleep { }
try { Get-WebText 'http://127.0.0.1:PORT/checksum'; exit 0 }
catch { Write-Output 'REQUEST_FAILED'; exit 9 }
'''.replace('PORT', str(server.server_port))
            try:
                result = subprocess.run([str(PWSH), '-NoLogo', '-NoProfile', '-Command', code],
                                        cwd=REPO, capture_output=True, text=True, timeout=15)
            finally:
                server.shutdown()
                thread.join(timeout=3)
        return requests, result

    def test_missing_checksum_is_not_retried(self):
        requests, result = self.run_response_sequence([404])
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(len(requests), 1)

    def test_transient_server_error_is_retried(self):
        requests, result = self.run_response_sequence([503, 503, 200])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 3)
        self.assertIn('publisher data', result.stdout)


if __name__ == '__main__':
    unittest.main()
