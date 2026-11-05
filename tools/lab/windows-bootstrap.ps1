param([string]$PayloadPath, [string]$AgentPath, [string]$ExpectedPayloadSha256, [string]$ExpectedAgentSha256)
$ErrorActionPreference = 'Stop'
$pc = Get-CimInstance Win32_ComputerSystem
if ($pc.Manufacturer -ne 'USBlessLab' -or $pc.Model -ne 'DisposableVM') { throw 'Not a disposable lab VM' }
$seed = (Get-Volume | Where-Object FileSystemLabel -eq 'USBDBSEED' | Select-Object -First 1).DriveLetter
if (-not $seed) { throw 'Lab seed media missing' }
$source = "$seed`:\"
$root = Join-Path $env:ProgramData 'USBlessLab'
$updatePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $updatePolicy -Force | Out-Null
New-ItemProperty -Path $updatePolicy -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
$sentinel = Join-Path $root 'preserve-sentinel.txt'
if ((Test-Path (Join-Path $root 'agent.json')) -and -not (Test-Path $sentinel)) {
    throw 'Existing preservation sentinel is missing; refusing to conceal data loss'
}
Stop-ScheduledTask -TaskName 'USBless disposable lab agent' -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $root -Force | Out-Null
if (-not $PayloadPath) { $PayloadPath = Join-Path $source 'payload.zip' }
elseif (-not $ExpectedPayloadSha256) { throw 'An incoming payload needs the expected host checksum' }
if (-not $AgentPath) { $AgentPath = Join-Path $source 'guest-agent.ps1' }
elseif (-not $ExpectedAgentSha256) { throw 'An incoming agent needs the expected host checksum' }
$fingerprint = (Get-FileHash $PayloadPath -Algorithm SHA256).Hash
if ($ExpectedPayloadSha256 -and $fingerprint -ne $ExpectedPayloadSha256) { throw 'Incoming payload checksum differs' }
if ($ExpectedAgentSha256 -and (Get-FileHash $AgentPath -Algorithm SHA256).Hash -ne $ExpectedAgentSha256) { throw 'Incoming agent checksum differs' }
$destination = Join-Path $root ('payloads\' + $fingerprint.ToLowerInvariant())
$receipt = Join-Path $root 'payload.sha256'
if (-not (Test-Path (Join-Path $destination 'complete.marker'))) {
    # Loaded .NET assemblies cannot always be overwritten. Stage a fresh version
    # and keep the previous files intact instead of forcing removal.
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Expand-Archive $PayloadPath $destination -Force
    if (-not (Test-Path (Join-Path $destination 'source\bin\Release\usbless.exe'))) { throw 'Payload extraction is incomplete' }
    Set-Content (Join-Path $destination 'complete.marker') $fingerprint
}
$agentConfig = Get-Content (Join-Path $source 'agent.json') -Raw | ConvertFrom-Json
$agentConfig | Add-Member -NotePropertyName payload -NotePropertyValue $destination -Force
$agentConfig | ConvertTo-Json | Set-Content (Join-Path $root 'agent.json') -Encoding UTF8
Copy-Item $AgentPath (Join-Path $root 'guest-agent.ps1') -Force
Set-Content $receipt $fingerprint
if (-not (Test-Path $sentinel)) { 'USBless incumbent-data preservation sentinel' | Set-Content $sentinel }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'guest-agent.ps1') + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User 'LabAdmin'
Register-ScheduledTask -TaskName 'USBless disposable lab agent' -Action $action -Trigger $trigger -User 'LabAdmin' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'USBless disposable lab agent'
