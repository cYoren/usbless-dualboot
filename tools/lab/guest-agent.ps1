# USBless disposable-VM agent. This is test infrastructure, never an app dependency.
$ErrorActionPreference = 'Stop'
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Manufacturer -ne 'USBlessLab' -or $computer.Model -ne 'DisposableVM') {
    throw 'This test agent refuses to run outside an explicitly marked disposable VM.'
}
$root = Join-Path $env:ProgramData 'USBlessLab'
$config = Get-Content (Join-Path $root 'agent.json') -Raw | ConvertFrom-Json
$exe = Join-Path $root 'payload\usbless.exe'
New-NetFirewallRule -DisplayName 'USBless isolated test agent' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 4777 -RemoteAddress 10.0.2.2 -ErrorAction SilentlyContinue | Out-Null
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, 4777)
$listener.Start()
Set-Content (Join-Path $root 'ready.txt') ([DateTime]::UtcNow.ToString('o'))
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        $request = $reader.ReadLine() | ConvertFrom-Json
        if ($request.token -cne $config.token) { throw 'Unauthorized lab request' }
        $result = switch ($request.action) {
            'status' {
                [pscustomobject]@{ ok = $true; machine = $computer.Model; manufacturer = $computer.Manufacturer
                    windows = (Get-CimInstance Win32_OperatingSystem).Caption; agent = 1
                    sentinel = (Get-FileHash (Join-Path $root 'preserve-sentinel.txt') -Algorithm SHA256).Hash
                    disks = @(Get-Disk | Select-Object Number, Guid, SerialNumber, Size, PartitionStyle) }
            }
            'tests' {
                Import-Module (Join-Path $root 'payload\Pester\Pester.psd1') -Force
                $testRoot = Join-Path $root 'payload\source\tests'
                $test = Invoke-Pester -Path $testRoot -PassThru -Output Detailed
                $report = [pscustomobject]@{ ok = $test.FailedCount -eq 0; passed = $test.PassedCount
                    failed = $test.FailedCount; skipped = $test.SkippedCount; total = $test.TotalCount
                    failures = @($test.Failed | ForEach-Object { $_.ExpandedName + ': ' + $_.ErrorRecord }) }
                $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'unit-results.json')
                $report
            }
            'ui' {
                if (-not (Test-Path $exe)) { throw 'Windows binary is absent' }
                $process = Start-Process $exe -PassThru
                [pscustomobject]@{ ok = $true; pid = $process.Id }
            }
            'shutdown' {
                $writer.WriteLine('{"ok":true,"action":"shutdown"}')
                Stop-Computer -Force
                continue
            }
            default { throw 'Unknown lab action' }
        }
        $writer.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
    } catch {
        try { $writer.WriteLine((@{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress)) } catch { }
    } finally { $client.Dispose() }
}
