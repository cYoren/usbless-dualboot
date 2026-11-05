# --- Main flows ------------------------------------------------------------

function Invoke-Install([string]$DistroId, [string]$IsoPath, [int]$LinuxGB, [string]$Target, [string]$DownloadDrive, [switch]$FullDisk) {
    Set-Stage 0
    Set-Status 'Checking this PC...'
    Test-System
    if ((Get-InstallStatus) -ne 'none') { throw 'usbless found changes from an earlier attempt. Clean them up first.' }
    $distro = Get-Distro $DistroId $IsoPath
    Assert-SecureBootAllows $distro
    Assert-FirmwareAccess
    Assert-DriveUsable $Target
    Assert-StateRoom
    # Replacing Windows only needs the installer, which the Linux installer later erases along with the rest.
    $strategy = $distro.Strategy
    if ($FullDisk) {
        Assert-FullDisk $distro
        $LinuxGB = 0
        $strategy = 'freespace'
    } else {
        Assert-SystemFitsDrive $distro $Target
        Assert-SystemFitsSpace $distro $LinuxGB
        Assert-NoBitLocker $distro $Target
    }
    $diskChanged = $false

    if (-not $IsoPath) {
        Set-Stage 1
        Set-Status "Finding the latest $($distro.Name) on $($distro.Source)..."
        $download = try { Resolve-Download $distro } catch {
            throw "Couldn't find the download on $($distro.Source): $($_.Exception.Message) Check the internet connection, or download the ISO yourself and pick ""Use an ISO file""."
        }
        Write-Log "Official download: $($download.Url)"
        $IsoPath = Join-Path (Get-DownloadFolder $DownloadDrive) $download.FileName
        Get-Iso $download $IsoPath
    } elseif (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "Can't find $IsoPath. Pick the ISO file again."
    }

    try {
        # Nothing on the disk changes until New-LinuxSpace.
        Set-Stage 2
        $iso = Read-Iso $IsoPath $distro
        if ($FullDisk) { Assert-FullDiskIso $distro $iso }
        $plan = Get-Plan $LinuxGB $iso.InstallerGB $Target $iso.LiveGB
        Use-Esp {
            param($root)
            Assert-EspRoom $root "$($iso.Letter):\EFI\BOOT" $(if ($FullDisk) { 0 } else { Get-EspLinuxMB $distro ($plan.DiskNumber -eq (Get-WindowsPartition).DiskNumber) })
            Assert-EspWritable $root
        }

        Set-Stage 3
        if (-not $Sync.Gate.EnterDiskStage()) { throw 'Cancelled.' }
        $disk = Get-Disk -Number $plan.DiskNumber
        $state = [pscustomobject]@{
            Distro = $distro.Name; DistroId = $distro.Id; Strategy = $strategy; LinuxGB = $LinuxGB; FullDisk = [bool]$FullDisk
            DiskNumber = $plan.DiskNumber; WindowsShrunk = $false; Partitions = @(); BootNumber = $null
            IsoPath = $IsoPath; Created = (Get-Date).ToString('s'); Copied = $false; RestartedAt = $null
            LoadersBefore = @(Get-LinuxLoaders $plan.DiskNumber | ForEach-Object { $_.Path })
            LinuxBefore = @(Get-LinuxPartitions @(Get-Partition -DiskNumber $plan.DiskNumber -ErrorAction SilentlyContinue) | ForEach-Object { $_.Guid })
            # WindowsShrunk and InstallerNextToWindows now mean the chosen drive, and keep their names so older files still read.
            FastStartupWasOn = (Get-FastStartup) -eq 1; BitLockerPaused = $false; InstallerNextToWindows = $plan.Kind -eq 'volume'
            DiskGuid = $disk.Guid; DiskName = Get-DiskLabel $disk; DiskGB = Get-DiskGB $disk
            OnWindowsDisk = $plan.DiskNumber -eq (Get-WindowsPartition).DiskNumber
            TargetKind = $plan.Kind; TargetLetter = $plan.Letter; TargetOffset = $plan.TargetOffset; AlongsideOk = $null
        }
        $diskChanged = $true
        Save-State $state
        $state.BitLockerPaused = Suspend-BitLockerForSetup
        Disable-FastStartup
        Save-State $state
        $installer = New-LinuxSpace $plan $strategy $state | Select-Object -Last 1
        $state.AlongsideOk = if ($FullDisk) { $null } else { try { Test-AlongsideFindsLinux $plan } catch { $null } }
        Save-State $state
        Restore-RoomSettings
        $letter = Get-DriveLetter $installer

        Set-Stage 4
        Copy-Installer $iso $letter
        if ($plan.LiveSize) {
            $live = Get-PartitionAt $plan.DiskNumber $plan.LiveOffset
            Copy-LiveFiles $iso (Get-DriveLetter $live)
            Remove-DriveLetter $live
        }
        Update-BootConfig $distro "$letter`:\" -FullDisk:$FullDisk
        if ($FullDisk -and -not (Test-FullDiskConfig $distro "$letter`:\")) {
            throw "usbless couldn't change $($distro.Name)'s startup menu to let go of the disk."
        }
        $state.Copied = $true
        Save-State $state
    } catch {
        # Leave the PC as it was: a half-made installer is worse than none.
        if ($diskChanged) {
            Write-Log "Failed: $($_.Exception.Message)"
            Write-Log 'Undoing the changes made so far...'
            try { Invoke-Cleanup } catch { Write-Log "Could not undo everything: $($_.Exception.Message)" }
        }
        throw
    } finally {
        try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch { }
    }

    # From here a failure doesn't undo anything: the installer is complete, and Restart
    # now tries the startup menu again and reports the problem if it persists. The one-time
    # start waits for Restart now: set here, a Windows Update restart would take it, however
    # long after someone clicked Later.
    Set-Stage 5
    try {
        $state.BootNumber = Register-Installer $distro.Name $distro
        Save-State $state
    } catch {
        Write-Log "Could not add the installer to the startup menu yet: $($_.Exception.Message)"
    }

    Set-Stage 6
    Set-Status 'Ready to restart.' 100
    Write-Log "You can delete $IsoPath once Linux is installed."
}

function Get-StartupInfo {
    $status = Get-InstallStatus
    # Only for a new install: what stops an install must not stop someone undoing one.
    if ($status -eq 'none') { Test-System }
    $state = Read-State
    # C: can't always be measured, for example when it isn't NTFS and usbless is here for another drive.
    $space = try { Get-SpaceInfo } catch { Write-Log "Could not measure C:: $($_.Exception.Message)"; $null }
    $volume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
    $disk = if ($space) { Get-Disk -Number $space.Partition.DiskNumber }
    $stuck = if ($space) { Get-StuckGB $volume.SizeRemaining $space } else { 0 }
    # Working this out takes a moment, and only matters when a lot is stuck.
    $blocker = if ($stuck -ge 20) { Get-ShrinkBlocker $space.Partition }
    $drives = @(try { Get-DriveTargets } catch { Write-Log "Could not list the drives: $($_.Exception.Message)" })
    $windowsRow = $drives | Where-Object Id -eq '' | Select-Object -First 1
    if ($windowsRow -and $space) {
        $windowsRow.UsableGB = $space.UsableGB; $windowsRow.StuckGB = $stuck; $windowsRow.Estimated = $false
        $windowsRow.TailFreeGB = [int][math]::Floor($space.TailFree / 1GB)
        $windowsRow.ShrinkBlocker = $blocker; $windowsRow.BlockerKind = Get-BlockerKind $blocker
    }
    $stateDisk = if ($state) { Get-StateDisk $state }
    # Free space gives no drive anything back. An older file can only mean C:.
    $stateLetter = $null
    if ($state) { $stateLetter = if ($state.TargetOffset) { $state.TargetLetter } else { $env:SystemDrive.TrimEnd(':') } }
    $other = try { Get-OtherSystem | Select-Object Name, SizeGB, OnWindowsDisk, Kept } catch { Write-Log "Could not look for another Linux: $($_.Exception.Message)"; $null }
    [pscustomobject]@{
        # C: on its own, for when the drives can't be listed.
        WindowsFallback = [pscustomobject]@{
            Id = ''; Kind = 'volume'; Letter = 'C'; Title = 'Drive C:'; OnWindowsDisk = $true
            DiskName  = Get-DiskLabel $disk
            SizeGB    = [int][math]::Floor($space.Partition.Size / 1GB)
            UsedGB    = [int][math]::Ceiling(($volume.Size - $volume.SizeRemaining) / 1GB)
            TailFreeGB = [int][math]::Floor($space.TailFree / 1GB)
            UsableGB  = $space.UsableGB
            StuckGB   = $stuck
            ShrinkBlocker = $blocker
            BlockerKind = Get-BlockerKind $blocker
        }
        RoomPhase = Get-RoomPhase
        Other     = $other
        Status    = $status
        Leftovers = @(if ($status -ne 'none') { try { Get-LeftoverList | Select-Object -Unique } catch { Write-Log "Could not list what usbless left: $($_.Exception.Message)" } })
        State     = $state
        CameBack  = $status -eq 'ready' -and (Test-CameBack $state)
        SecureBoot = Test-SecureBoot
        BootKey   = Get-BootMenuKey
        Drives    = $drives
        DownloadDrives = @(try { Get-DownloadDrives } catch { Write-Log "Could not list the drives for the download: $($_.Exception.Message)" })
        RoomLetter = (Read-RoomState).Drive -replace ':', ''
        StateLetter = $stateLetter
        StateDiskMissing = $state -and $null -eq $stateDisk
    }
}

# True when usbless restarted the PC for the installer and Windows has started since.
function Test-CameBack($State) {
    if (-not $State.RestartedAt) { return $false }
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt [datetime]$State.RestartedAt
}

# A system removed from the catalog since the install still needs its steps and boot loader.
function Get-StateDistro($State) {
    $distro = Get-Distro $State.DistroId $State.IsoPath
    if (-not $distro) { $distro = Get-Distro 'custom' "$($State.Distro).iso" }
    $distro
}

function Get-StateSteps {
    $state = Read-State
    Get-Steps (Get-StateDistro $state) $state.LinuxGB $state
}

function Restart-IntoInstaller {
    Set-InstallerForNextStart
    Invoke-InstallerRestart '/r', '/t', '0'
}

# The BIOS settings, for turning off Secure Boot. Leaving them starts the installer.
function Restart-IntoFirmware {
    Set-InstallerForNextStart
    Invoke-InstallerRestart '/r', '/fw', '/t', '0'
}

# With no restart, the one-time start would wait for whichever came next, however much later.
function Invoke-InstallerRestart([string[]]$Arguments) {
    try { Invoke-Shutdown $Arguments } catch {
        try { Clear-BootOnce } catch { Write-Log "Could not forget the one-time start: $($_.Exception.Message)" }
        # It never went, so coming back to this screen isn't the installer failing to start.
        try { $state = Read-State; $state.RestartedAt = $null; Save-State $state } catch { Write-Log "Could not save that the PC didn't restart: $($_.Exception.Message)" }
        throw
    }
}

function Set-InstallerForNextStart {
    $others = @(Get-OtherInstallers)
    $usb = $others | Where-Object Usb | Select-Object -First 1
    if ($usb) { throw "Unplug $($usb.Name) and try again. It also holds a Linux installer, and the PC could start that one instead." }
    # Can't be unplugged, and may well be fine, so it's in the warnings and doesn't block.
    foreach ($other in $others) { Write-Log "Another installer is on $($other.Name); the PC could start that one instead." }
    $state = Read-State
    # It holds the space the installer is about to look for.
    if (-not (Test-LinuxInstalled $state)) { Remove-CasperPartition $state }
    Suspend-BitLockerForRestart $state
    $state.BootNumber = Register-Installer $state.Distro (Get-StateDistro $state)
    Set-BootOnce ([int]$state.BootNumber)
    # Builds before this one didn't have the field, so it may need adding.
    $state | Add-Member -NotePropertyName RestartedAt -NotePropertyValue (Get-Date).ToString('s') -Force
    Save-State $state
}

function Invoke-Shutdown([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & shutdown.exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Windows could not restart this PC: $($output.Trim())" }
}

# The volume that gave up the space usbless is about to free, as a disk and an offset, or nothing
# when it came from free space. Older state files and plain leftovers on the Windows disk mean C:.
function Get-SpaceOwner($State, $UsblessPartitions) {
    if ($State -and $null -ne $State.TargetOffset) {
        if ($State.TargetKind -eq 'gap') { return }
        $disk = Get-StateDisk $State
        if ($null -eq $disk) { Write-Log 'The drive this setup is on is not connected.'; return }
        $c = Get-PartitionAt $disk ([int64]$State.TargetOffset)
        $windows = $c -and $c.IsBoot
        return [pscustomobject]@{ DiskNumber = $disk; Offset = [int64]$State.TargetOffset; Windows = [bool]$windows }
    }
    $windows = [pscustomobject]@{ Windows = $true }
    if ($State) { return $windows }
    $windowsDisk = (Get-WindowsPartition).DiskNumber
    $first = @($UsblessPartitions | Where-Object { $_.Partition.DiskNumber -ne $windowsDisk } | Sort-Object { [int64]$_.Partition.Offset }) | Select-Object -First 1
    if (-not $first) { return $windows }
    $disk = $first.Partition.DiskNumber
    $before = @(Get-Partition -DiskNumber $disk -ErrorAction SilentlyContinue | Where-Object { [int64]$_.Offset -lt [int64]$first.Partition.Offset } | Sort-Object { [int64]$_.Offset }) | Select-Object -Last 1
    if (-not $before -or -not (Get-LetterOf $before)) { return }
    if (($before | Get-Volume -ErrorAction SilentlyContinue).FileSystemType -ne 'NTFS') { return }
    [pscustomobject]@{ DiskNumber = $disk; Offset = [int64]$before.Offset; Windows = $false }
}

# Removes what usbless made: its startup entries and partitions, found by their
# description and labels, so this also works when an earlier attempt failed half way.
# With -InstallerOnly, Linux and its partitions stay.
function Invoke-Cleanup([switch]$InstallerOnly) {
    $state = Read-State
    $Sync.SpaceNote = $null
    # While Make room's settings are off, its safety net is what brings them back.
    if (-not (Test-Path -LiteralPath $RoomPath)) { Unregister-RunAfterRestart }
    # Choosing "Linux isn't installed yet" by mistake must not take its boot partition with it.
    if (-not $InstallerOnly -and $state -and (Test-LinuxInstalled $state)) {
        Write-Log 'Linux is installed, so only the installer will be removed.'
        $InstallerOnly = [switch]$true
    }
    Set-Status 'Removing usbless from the startup menu...'
    foreach ($id in @(Get-BcdEntries)) {
        try { Invoke-Bcdedit /delete $id | Out-Null; Write-Log "Removed startup entry $id." } catch { Write-Log "Could not remove $id." }
    }
    foreach ($number in @(Get-FirmwareEntries)) {
        # One the firmware refuses must not stop the rest. It still has usbless's name, so it can be found later.
        try {
            Remove-FirmwareEntry $number
            Write-Log ('Removed startup entry Boot{0:X4}.' -f $number)
        } catch { Write-Log ('Could not remove startup entry Boot{0:X4}: {1}' -f $number, $_.Exception.Message) }
    }
    try {
        Use-Esp {
            param($root)
            foreach ($name in $EspFolders) {
                $folder = Join-Path $root $name
                if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force; Write-Log "Removed \$name." }
            }
        }
    } catch { Write-Log "Could not tidy the EFI system partition: $($_.Exception.Message)" }

    $labels = if ($InstallerOnly) { $InstallerLabels + $LiveLabel } else { $InstallerLabels + $LiveLabel, $RootLabel, $BootLabel }
    $usblessPartitions = @(Get-UsblessPartitions | Where-Object { $_.Label -in $labels })
    # Before anything goes: with no state file, the neighbours say whose space it was.
    $owner = try { Get-SpaceOwner $state $usblessPartitions } catch { Write-Log "Could not tell whose space it was: $($_.Exception.Message)"; $null }
    # A crash can come after a shrink and before saying it happened. Only its real size says so, so
    # a drive that never shrank still doesn't take free space that was already there.
    if ($owner -and $state.SizeBeforeShrink -and $state.WindowsShrunk -eq $false) {
        try {
            $drive = if ($owner.Windows) { Get-WindowsPartition } else { Get-PartitionAt $owner.DiskNumber $owner.Offset }
            if ($drive -and [int64]$drive.Size -lt [int64]$state.SizeBeforeShrink) { $state.WindowsShrunk = $true }
        } catch { Write-Log "Could not tell whether the drive shrank: $($_.Exception.Message)" }
    }
    # Also before anything goes: it's known by where it starts, next to the installer. With Linux
    # staying, it stays too, because Windows can't see whether that Linux is using it. Failing here
    # only leaves that partition behind, and the rest still has to happen.
    if ($state -and -not $InstallerOnly) {
        try { Remove-CasperPartition $state } catch { Write-Log "Could not remove the partition the live system made: $($_.Exception.Message)" }
    }
    foreach ($found in $usblessPartitions) {
        Set-Status "Removing the $($found.Label) partition..."
        Remove-PartitionAt $found.Partition.DiskNumber $found.Partition.Offset
    }
    $roles = if ($InstallerOnly) { @('installer', 'live') } else { @('installer', 'live', 'root', 'boot') }
    foreach ($partition in @(Get-RecordedPartitions $state $roles)) {
        Set-Status 'Removing an unfinished partition...'
        Remove-PartitionAt $partition.DiskNumber $partition.Offset
    }

    # Free space that was next to the drive before usbless started stays free, unless it was shrunk.
    # With Linux staying, the installer's space goes to that drive, if it's next to it: builds
    # before InstallerNextToWindows put it after Linux, where Windows can't reach it.
    $growWindows = if ($InstallerOnly) { $state.InstallerNextToWindows } else { $null -eq $state -or $state.WindowsShrunk -ne $false }
    # Growing over the installer also takes whatever was left free before it. Another drive that
    # never gave anything up keeps its size, so that free space stays free for someone to use.
    if ($owner -and -not $owner.Windows -and $state.WindowsShrunk -eq $false) { $growWindows = $false }
    if ($growWindows -and $owner) {
        try {
            # Looked up again now: numbers can shift once partitions have gone, and offsets can't.
            $c = if ($owner.Windows) { Get-WindowsPartition } else { Get-PartitionAt $owner.DiskNumber $owner.Offset }
            if (-not $c) { throw "The drive that gave up the space isn't there any more." }
            $max = (Get-SupportedSize $c).SizeMax
            if ($max -gt $c.Size + 1MB) {
                Set-Status "Giving the space back to $(if ($owner.Windows) { 'Windows' } else { "drive $(Get-LetterOf $c):" })..."
                Resize-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -Size $max
            } else {
                # For example, Windows has made a recovery partition straight after C: since.
                Write-Log 'The freed space is not next to the drive, so Windows cannot use it directly.'
            }
        } catch {
            # The partitions are gone by now, so trying again couldn't help, and the rest still has to happen.
            Write-Log "Could not give the space back: $($_.Exception.Message)"
            $Sync.SpaceNote = "The space it used stays free, because usbless couldn't give it back to the drive it came from. That drive may be gone, or Windows may have refused."
        }
    }

    # So usbless can offer to remove it later: nothing else would say that Linux on this disk is usbless's.
    if ($InstallerOnly -and $state.OnWindowsDisk -eq $false) { Add-LinuxDisk $state.DiskGuid }

    # Only without Linux: Fast Startup stays off for a dual boot, because it locks the Windows drive.
    if (-not $InstallerOnly) {
        if ($state.FastStartupWasOn) { try { Restore-FastStartup } catch { Write-Log "Could not turn Fast Startup back on: $($_.Exception.Message)" } }
        if ($state.BitLockerPaused) { try { Resume-BitLockerAfterUndo } catch { Write-Log "Could not turn BitLocker back on: $($_.Exception.Message)" } }
    }

    foreach ($path in @($StatePath, $LegacyStatePath)) { if (Test-Path $path) { Remove-Item -LiteralPath $path -Force } }
    Set-Status 'usbless changes removed.' 100
}
