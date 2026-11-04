param(
    [ValidateSet('plan', 'prepare', 'cleanup')][string]$Action,
    [ValidateRange(1024, 65535)][int]$MediaPort = 8765,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSentinel,
    [string]$PlanId
)
$ErrorActionPreference = 'Stop'
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Manufacturer -ne 'USBlessLab' -or $computer.Model -ne 'DisposableVM') {
    throw 'This case only runs inside the marked disposable VM'
}
$labRoot = Join-Path $env:ProgramData 'USBlessLab'
$sentinelPath = Join-Path $labRoot 'preserve-sentinel.txt'
$before = (Get-FileHash $sentinelPath -Algorithm SHA256).Hash
if (-not $ExpectedSentinel -or $before -ne $ExpectedSentinel) { throw 'Preservation baseline differs' }
. (Join-Path $PSScriptRoot 'source\tests\Load-Engine.ps1') -WithUsbless
$windows = Get-WindowsPartition
$disk = Get-Disk -Number $windows.DiskNumber
if ($windows.DiskNumber -ne 0 -or $disk.SerialNumber.Trim() -ne 'USBDBLABSYSTEM') {
    throw 'The Windows disk does not have the expected private lab identity'
}
[void][Usbless.StateFolder]::Protect($StateDir, $true)
$Sync.Gate = New-Object Usbless.CancelGate

if ($Action -eq 'cleanup') {
    $state = Read-State
    if (-not $state -or $state.DistroId -ne 'fedora-kde') { throw 'This case does not own the saved preparation' }
    # This case validates retiring the carrier after installation, never removing Linux.
    Invoke-Cleanup -InstallerOnly | Out-Null
    [pscustomobject]@{ ok = $true; action = $Action; sentinel = (Get-FileHash $sentinelPath -Algorithm SHA256).Hash; status = Get-InstallStatus }
    return
}

$fingerprint = 'c8295961d4c41adbf785a31a17c21a971d3b7415fda72dcad0c11c49577bf03a'
$media = Join-Path $labRoot 'media'
New-Item -ItemType Directory -Path $media -Force | Out-Null
$path = Join-Path $media 'Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso'
if (-not (Test-Path -LiteralPath $path)) {
    # The host serves its already verified cache; this does not fetch another ISO
    # from the Internet. The fixed address is QEMU's private host-loopback gateway.
    $partial = "$path.part"
    & "$env:SystemRoot\System32\curl.exe" --fail --silent --show-error --continue-at - --retry 2 `
        --output $partial "http://10.0.2.2:$MediaPort/media.iso"
    if ($LASTEXITCODE) { throw "Local media transfer failed: curl $LASTEXITCODE" }
    Move-Item -LiteralPath $partial -Destination $path -ErrorAction Stop
}
if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $fingerprint) {
    throw 'The cached guest ISO differs from the publisher checksum; bytes retained'
}
$distro = Get-Distro 'fedora-kde' $path
try {
    Test-System
    $iso = Read-Iso $path $distro
    $plan = Get-Plan 25 $iso.InstallerGB '' $iso.LiveGB
    $identity = [ordered]@{
        disk_guid = [string]$disk.Guid
        windows_guid = [string]$windows.Guid
        windows_size = [int64]$windows.Size
        iso_sha256 = $fingerprint
        plan = $plan
    }
    $serialized = $identity | ConvertTo-Json -Depth 8 -Compress
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $token = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($serialized)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
} finally {
    Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null
}
if ($Action -eq 'plan') {
    [pscustomobject]@{ ok = $true; action = 'plan'; plan_id = $token; identity = $identity; sentinel = $before }
    return
}
if (-not $PlanId -or $PlanId -cne $token) { throw 'Plan changed or was not reviewed; refusing preparation' }
Invoke-Install -DistroId 'fedora-kde' -IsoPath $path -LinuxGB 25 -Target '' -DownloadDrive '' | Out-Null
$after = (Get-FileHash $sentinelPath -Algorithm SHA256).Hash
if ($after -ne $before) { throw 'The incumbent data sentinel changed during preparation' }
$prepared = Read-State
$registered = $null -ne $prepared.BootNumber -and [string]$prepared.BootNumber -ne ''
[pscustomobject]@{ ok = [bool]$prepared.Copied -and $registered; action = 'prepare'; sentinel = $after
    boot_registered = $registered; state = $prepared; status = Get-InstallStatus }
