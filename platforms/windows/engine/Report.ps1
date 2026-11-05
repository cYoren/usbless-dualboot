# A plain-text report to paste into a GitHub issue: the PC, the disk layout, the startup
# menu and the log. No serial numbers, and the user and computer names are taken out.

function Add-ReportSection($Lines, [string]$Title, [scriptblock]$Read) {
    $Lines.Add('')
    $Lines.Add("## $Title")
    try { foreach ($line in @(& $Read)) { $Lines.Add([string]$line) } }
    catch { $Lines.Add("(could not read: $($_.Exception.Message))") }
}

function Remove-PersonalNames([string]$Text) {
    foreach ($name in @($env:USERPROFILE, $env:USERNAME, $env:COMPUTERNAME)) {
        if ($name) { $Text = $Text -ireplace [regex]::Escape($name), '<hidden>' }
    }
    $Text
}

function Get-Report {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("usbless $($Sync.Version)")

    Add-ReportSection $lines 'PC' {
        $os = Get-CimInstance Win32_OperatingSystem
        $pc = Get-CimInstance Win32_ComputerSystem
        "Windows: $($os.Caption) build $($os.BuildNumber)"
        "Model: $($pc.Manufacturer) $($pc.Model)"
        "Memory: $([math]::Round($pc.TotalPhysicalMemory / 1GB)) GB"
        "Firmware: $(if (Test-Uefi) { 'UEFI' } else { 'Legacy BIOS' }), Secure Boot $(if (Test-SecureBoot) { 'on' } else { 'off or unknown' })"
    }
    Add-ReportSection $lines 'usbless' {
        "Status: $(Get-InstallStatus)"
        $state = Read-State
        if ($state) {
            "Distro: $($state.DistroId), $($state.LinuxGB) GB, copied: $($state.Copied), restarted: $($state.RestartedAt)"
            "Target: $($state.TargetKind) $($state.TargetLetter) at $($state.TargetOffset), on the Windows disk: $($state.OnWindowsDisk), alongside finds it: $($state.AlongsideOk)"
        }
    }
    Add-ReportSection $lines 'Disk' {
        $c = Get-WindowsPartition
        $disk = Get-Disk -Number $c.DiskNumber
        "$($disk.FriendlyName), $($disk.BusType), $($disk.PartitionStyle), $([math]::Round($disk.Size / 1GB)) GB, $($disk.LogicalSectorSize)-byte sectors"
        $space = Get-SpaceInfo
        "C: free $([math]::Floor((Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')).SizeRemaining / 1GB)) GB, can shrink to $([math]::Ceiling($space.MinSize / 1GB)) GB, usable $($space.UsableGB) GB"
        "Last file Windows can't move: $(Get-ShrinkBlocker). Make room: $(Get-RoomPhase)"
        foreach ($p in Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset) {
            $volume = try { $p | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
            $signature = try { [Usbless.DiskProbe]::ReadSignature($p.DiskNumber, [int64]$p.Offset) } catch { 'unread' }
            '{0,2}  {1,8:N1} GB at {2,8:N1} GB  {3}  {4} {5} {6}' -f $p.PartitionNumber, ($p.Size / 1GB), ($p.Offset / 1GB), $p.GptType, $volume.FileSystemType, $volume.FileSystemLabel, $signature
        }
    }
    Add-ReportSection $lines 'Drives' {
        foreach ($row in Get-DriveTargets) {
            "$($row.Title), $($row.DiskName), $($row.DiskGB) GB disk, about $($row.UsableGB) GB usable. $($row.Blocker)"
        }
        foreach ($disk in Get-Disk | Where-Object Number -ne (Get-WindowsPartition).DiskNumber) {
            "Disk $($disk.Number): $($disk.BusType), $($disk.PartitionStyle), $([math]::Round($disk.Size / 1GB)) GB, $($disk.HealthStatus)"
        }
    }
    Add-ReportSection $lines 'Secure Boot' {
        "Trusted: $((Get-UefiAuthorities (Get-SecureBootDb)) -join ', ')"
    }
    Add-ReportSection $lines 'Startup menu' {
        $order = ([Usbless.Firmware]::BootOrderNumbers() | ForEach-Object { '{0:X4}' -f $_ }) -join ' '
        $next = [Usbless.Firmware]::BootNext()
        "BootCurrent $('{0:X4}' -f [Usbless.Firmware]::BootCurrent()), BootNext $(if ($null -eq $next) { 'not set' } else { '{0:X4}' -f $next }), BootOrder $order"
        foreach ($entry in [Usbless.Firmware]::ListEntries()) {
            'Boot{0:X4}  {1}  {2}' -f $entry.Number, $entry.Description, $entry.Path
        }
    }
    Add-ReportSection $lines 'Log' {
        if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Tail 200 } else { @($Sync.Log) }
    }
    Remove-PersonalNames ($lines -join [Environment]::NewLine)
}
