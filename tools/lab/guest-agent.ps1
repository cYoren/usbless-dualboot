# USBless disposable-VM agent. This is test infrastructure, never an app dependency.
$ErrorActionPreference = 'Stop'
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Manufacturer -ne 'USBlessLab' -or $computer.Model -ne 'DisposableVM') {
    throw 'This test agent refuses to run outside an explicitly marked disposable VM.'
}
$root = Join-Path $env:ProgramData 'USBlessLab'
$config = Get-Content (Join-Path $root 'agent.json') -Raw | ConvertFrom-Json
$payload = if ($config.payload) { [IO.Path]::GetFullPath([string]$config.payload) } else { Join-Path $root 'payload' }
if ($payload -ne (Join-Path $root 'payload') -and -not $payload.StartsWith((Join-Path $root 'payloads\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Payload must stay inside the private lab directory'
}
$exe = Join-Path $payload 'usbless.exe'
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
                    windows = (Get-CimInstance Win32_OperatingSystem).Caption; agent = 2
                    payload_sha256 = (Get-Content (Join-Path $root 'payload.sha256') -Raw).Trim()
                    sentinel = (Get-FileHash (Join-Path $root 'preserve-sentinel.txt') -Algorithm SHA256).Hash
                    disks = @(Get-Disk | Select-Object Number, Guid, SerialNumber, Size, PartitionStyle) }
            }
            'tests' {
                Import-Module (Join-Path $payload 'Pester\Pester.psd1') -Force
                $testRoot = Join-Path $payload 'source\tests'
                $test = Invoke-Pester -Path $testRoot -PassThru -Output Detailed
                $containers = @($test.Containers | Where-Object Result -eq 'Failed')
                $report = [pscustomobject]@{ ok = $test.FailedCount -eq 0 -and $containers.Count -eq 0; passed = $test.PassedCount
                    failed = $test.FailedCount; skipped = $test.SkippedCount; total = $test.TotalCount
                    failures = @($test.Failed | ForEach-Object { $_.ExpandedName + ': ' + $_.ErrorRecord })
                    container_failures = @($containers | ForEach-Object { [pscustomobject]@{
                        file = [string]$_.Item; errors = @($_.ErrorRecord | ForEach-Object { $_.ToString() }) } }) }
                $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'unit-results.json')
                $report
            }
            'inspect' {
                # Keep diagnostics independent of engine/test scope and assemblies.
                $windows = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
                $disk = Get-Disk -Number $windows.DiskNumber
                if ($disk.SerialNumber.Trim() -ne 'USBDBLABSYSTEM') { throw 'Unexpected lab system disk' }
                $savedState = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'usbless\state.json'
                $snapshot = if (Test-Path -LiteralPath $savedState) { Get-Content -LiteralPath $savedState -Raw | ConvertFrom-Json } else { $null }
                [pscustomobject]@{ ok = $true; state = $snapshot
                    sentinel = (Get-FileHash (Join-Path $root 'preserve-sentinel.txt') -Algorithm SHA256).Hash
                    disk = $disk | Select-Object Number, Guid, SerialNumber, Size
                    partitions = @(Get-Partition -DiskNumber $disk.Number | Select-Object PartitionNumber, Guid, Offset, Size, GptType, DriveLetter)
                    firmware = @(& bcdedit.exe /enum firmware)
                }
            }
            'ui' {
                if (-not (Test-Path $exe)) { throw 'Windows binary is absent' }
                $process = Start-Process $exe -PassThru
                [pscustomobject]@{ ok = $true; pid = $process.Id }
            }
            { $_ -in 'plan-kde', 'prepare-kde', 'cleanup-kde' } {
                $action = switch ($request.action) { 'plan-kde' { 'plan' }; 'prepare-kde' { 'prepare' }; 'cleanup-kde' { 'cleanup' } }
                & (Join-Path $payload 'case-fedora-kde.ps1') -Action $action `
                    -MediaPort $request.media_port -ExpectedSentinel $request.sentinel -PlanId $request.plan_id
            }
            'shutdown' {
                $writer.WriteLine('{"ok":true,"action":"shutdown"}')
                Stop-Computer -Force
                continue
            }
            'reboot' {
                $writer.WriteLine('{"ok":true,"action":"reboot"}')
                & shutdown.exe /r /t 0
                continue
            }
            default { throw 'Unknown lab action' }
        }
        $writer.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
    } catch {
        try { $writer.WriteLine((@{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress)) } catch { }
    } finally { $client.Dispose() }
}
