# --- What usbless left on this PC ------------------------------------------
# Everything usbless makes is recognisable without the state file: partitions by
# their labels, startup entries by "(usbless)" in their description.

# What's at the top of a volume, whether or not it has a letter.
function Get-VolumeEntries($Volume) {
    @([IO.Directory]::GetFileSystemEntries($Volume.Path) | ForEach-Object { [IO.Path]::GetFileName($_) })
}

# Without a record of making it, a volume with one of usbless's names is only usbless's if it looks that way:
# as it was formatted, or for the installer, holding a boot loader. Anyone's own files mean it isn't,
# and so does not being able to look. Windows puts its own folders on any drive.
function Test-LooksLikeUsbless($Volume) {
    $entries = try { @(Get-VolumeEntries $Volume) } catch { Write-Log "Could not look inside $($Volume.FileSystemLabel): $($_.Exception.Message)"; return $false }
    $entries = @($entries | Where-Object { $_ -notin @('System Volume Information', '$RECYCLE.BIN') })
    if (-not $entries.Count) { return $true }
    if ($Volume.FileSystemLabel -eq $LiveLabel) { return $entries -contains 'arch' }
    $Volume.FileSystemLabel -in $InstallerLabels -and $entries -contains 'EFI'
}

# Looks on every disk usbless could have used, because a crash can leave its state file behind or
# out of date. Off the Windows disk, a label alone isn't enough: the format has to match too,
# so someone's own drive named USBLBOOT isn't mistaken for usbless's.
function Get-UsblessPartitions {
    $windowsDisk = (Get-WindowsPartition).DiskNumber
    $recorded = @((Read-State).Partitions | Where-Object { $_ })
    foreach ($disk in @(Get-UsblessDisks)) {
        foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
            $volume = try { $partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
            if (-not $volume -or $volume.FileSystemLabel -notin ($InstallerLabels + $BootLabel, $RootLabel, $LiveLabel)) { continue }
            if ($disk.Number -ne $windowsDisk) {
                $format = if ($volume.FileSystemLabel -in $RootLabel, $LiveLabel) { 'exFAT' } else { 'FAT32' }
                if ($volume.FileSystemType -ne $format) { continue }
            }
            $isRecorded = @($recorded | Where-Object { [int64]$_.Offset -eq [int64]$partition.Offset -and [int64]$_.Size -eq [int64]$partition.Size }).Count -gt 0
            if (-not $isRecorded -and -not (Test-LooksLikeUsbless $volume)) { continue }
            [pscustomobject]@{ Partition = $partition; Label = $volume.FileSystemLabel; Letter = $volume.DriveLetter }
        }
    }
}

# What Clean up would delete, in words, so that it can be shown first.
function Get-LeftoverList {
    $describe = {
        param($Partition, [string]$Name)
        $letter = Get-LetterOf $Partition
        $disk = Get-DiskLabel (Get-Disk -Number $Partition.DiskNumber)
        "**$Name**, $([int][math]::Round([int64]$Partition.Size / 1GB)) GB$(if ($letter) { ", drive $letter`:" }), on $disk"
    }
    foreach ($found in @(Get-UsblessPartitions)) { & $describe $found.Partition $found.Label }
    foreach ($partition in @(Get-RecordedPartitions (Read-State) @('installer', 'live', 'root', 'boot'))) { & $describe $partition 'An unfinished partition' }
    foreach ($id in @(Get-FirmwareEntries) + @(Get-BcdEntries)) { if ($null -ne $id) { "usbless's entry in the startup menu" } }
}

function Get-FirmwareEntries {
    try { @($EntryMarkers | ForEach-Object { [Usbless.Firmware]::FindEntries($_) }) } catch { Write-Log "Could not read startup entries: $($_.Exception.Message)"; @() }
}

# Earlier usbless builds made startup entries with bcdedit; those live in the BCD store.
function Get-BcdEntries {
    $text = try { Invoke-Bcdedit /enum all } catch { '' }
    foreach ($block in ($text -split '(?:\r?\n){2,}')) {
        if ($block -match $EntryPattern) {
            $id = [regex]::Match($block, '\{[0-9a-fA-F-]{36}\}').Value
            if ($id) { $id }
        }
    }
}

# 'ready'    an installer is in place and set up to start
# 'installed' the installer is still here, and Linux has been installed from it
# 'leftover' something from an earlier attempt is left behind
# 'none'     nothing from usbless on this PC
function Get-InstallStatus {
    $state = Read-State
    $partitions = @(Get-UsblessPartitions)
    $entries = @(Get-FirmwareEntries)
    $installer = $partitions | Where-Object { $_.Label -in $InstallerLabels } | Select-Object -First 1
    # Finished copying is what counts. The startup entry isn't required: some firmwares
    # delete entries, and Restart now makes a fresh one. Builds before Copied existed only
    # set BootNumber once the copy was done.
    $copied = $state -and ($state.Copied -or $null -ne $state.BootNumber)
    if ($copied -and $installer) {
        # Windows doesn't always give the partition its letter back after a restart.
        $letter = if ($installer.Letter) { $installer.Letter } else { try { Get-DriveLetter $installer.Partition } catch { $null } }
        if ($letter -and (Test-Path -LiteralPath "$($letter):\EFI\BOOT\BOOTX64.EFI")) {
            if (Test-LinuxInstalled $state) { return 'installed' }
            return 'ready'
        }
    }
    if ($state -or $partitions.Count -or $entries.Count -or @(Get-BcdEntries).Count) { return 'leftover' }
    'none'
}

# A Linux boot loader or partition that wasn't there when the install began. Partitions
# count too because firmware can drop a startup entry, and Linux must not look absent then.
function Test-LinuxInstalled($State) {
    $names = $State.PSObject.Properties.Name
    if ($names -notcontains 'LoadersBefore') { return $false }
    $disk = Get-StateDisk $State
    if (@(Get-LinuxLoaders $disk | Where-Object { $_.Path -notin @($State.LoadersBefore) }).Count) { return $true }
    if ($names -notcontains 'LinuxBefore' -or $null -eq $disk) { return $false }
    $partitions = @(Get-Partition -DiskNumber $disk -ErrorAction SilentlyContinue)
    $casper = @(Get-CasperPartition $State $partitions | ForEach-Object { $_.Guid })
    @(Get-LinuxPartitions $partitions | Where-Object { $_.Guid -notin @($State.LinuxBefore) -and $_.Guid -notin $casper }).Count -gt 0
}

# The partition casper made for its logs when this setup's installer started, on a build of usbless that
# didn't tell it not to. See Get-CasperBoot. It isn't Linux, and it's holding Linux's space. A partition
# called writable could be anyone's, so everything has to point at this: usbless did start the installer,
# the partition is new since, it's after the installer, it's the last on the disk, it starts just where
# casper would put it, it has casper's type, and it holds casper's file system. Or none at all,
# because casper's mkfs loses a race on some boots, as seen on elementary OS.
function Get-CasperPartition($State, $Partitions) {
    if (-not $State.RestartedAt -or $State.PSObject.Properties.Name -notcontains 'LinuxBefore') { return }
    $installer = @($State.Partitions | Where-Object Role -eq 'installer') | Select-Object -First 1
    $sorted = @($Partitions | Sort-Object { [int64]$_.Offset + [int64]$_.Size })
    if (-not $installer -or $sorted.Count -lt 2) { return }
    $last = $sorted[-1]
    $before = $sorted[-2]
    if ($last.DiskNumber -ne (Get-StateDisk $State)) { return }
    if ($last.GptType -ne $LinuxPartitionTypes[0] -or $last.Guid -in @($State.LinuxBefore)) { return }
    if ([int64]$last.Offset -lt [int64]$installer.Offset + [int64]$installer.Size) { return }
    # Casper starts at the first multiple of 4096 sectors after the last partition.
    $boundary = [int64]4096 * (Get-Disk -Number $last.DiskNumber).LogicalSectorSize
    if ($boundary -le 0) { return }
    $end = [int64]$before.Offset + [int64]$before.Size
    if ([int64]$last.Offset -ne [int64]([math]::Ceiling($end / $boundary)) * $boundary) { return }
    if (Test-CasperContents $last) { $last }
}

function Test-CasperContents($Partition) {
    $head = try { [Usbless.DiskProbe]::ReadHead($Partition.DiskNumber, [int64]$Partition.Offset) } catch {
        Write-Log "Could not read partition $($Partition.PartitionNumber): $($_.Exception.Message)"
        return $false
    }
    [Usbless.DiskProbe]::ExtLabel($head) -ceq 'writable' -or [Usbless.DiskProbe]::IsBlank($head)
}

function Remove-CasperPartition($State) {
    if (-not $State.RestartedAt) { return }
    $disk = Get-StateDisk $State
    if ($null -eq $disk) { return }
    $partition = Get-CasperPartition $State @(Get-Partition -DiskNumber $disk -ErrorAction SilentlyContinue)
    if (-not $partition) { return }
    Set-Status 'Removing the partition the live system made...'
    Remove-PartitionAt $partition.DiskNumber $partition.Offset
}

function Get-VolumeOf($Partition) { try { $Partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null } }

function Read-PartitionHead($Partition) { [Usbless.DiskProbe]::ReadHead($Partition.DiskNumber, [int64]$Partition.Offset) }

# Partitions usbless recorded but may not have got as far as labelling, for example when formatting
# failed. It takes all of this to count: no file system Windows knows, a type that doesn't say Linux,
# and nothing written at its start. Windows can't read ext4 either, and a Linux installer may have
# been there since. Not being able to look means it stays.
function Get-RecordedPartitions($State, [string[]]$Roles) {
    $recorded = @($State.Partitions | Where-Object { $_.Role -in $Roles })
    if (-not $recorded.Count) { return }
    $disk = Get-StateDisk $State
    if ($null -eq $disk) { return }
    foreach ($partition in @(Get-Partition -DiskNumber $disk -ErrorAction SilentlyContinue)) {
        $match = $recorded | Where-Object { [int64]$_.Offset -eq [int64]$partition.Offset -and [int64]$_.Size -eq [int64]$partition.Size }
        if (-not $match -or $partition.IsSystem -or $partition.IsBoot -or $partition.GptType -in $LinuxPartitionTypes) { continue }
        $volume = Get-VolumeOf $partition
        if ($volume -and $volume.FileSystemType -and $volume.FileSystemType -ne 'Unknown') { continue }
        $head = try { Read-PartitionHead $partition } catch {
            Write-Log "Could not read partition $($partition.PartitionNumber), so it stays: $($_.Exception.Message)"
            continue
        }
        if ([Usbless.DiskProbe]::IsBlank($head)) { $partition }
    }
}

# Write then swap, so losing power mid-write can't leave half a file. The new file is on the disk before
# it takes the old one's place, and its name can't be guessed, so nothing can be waiting there.
function Write-StateFile([string]$Path, [string]$Text) {
    $folder = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { [void][Usbless.StateFolder]::Protect($folder, $true) }
    $temporary = Join-Path $folder ([IO.Path]::GetRandomFileName())
    $bytes = (New-Object Text.UTF8Encoding($true)).GetBytes($Text)
    $preamble = (New-Object Text.UTF8Encoding($true)).GetPreamble()
    try {
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($preamble, 0, $preamble.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) } else { [IO.File]::Move($temporary, $Path) }
    } catch {
        [IO.File]::Delete($temporary)
        throw
    }
}

function Save-State($State) {
    Write-StateFile $StatePath ($State | ConvertTo-Json -Depth 5)
}

function Read-State {
    $path = @($StatePath, $LegacyStatePath) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $path) { return }
    # usbless.exe checked this as it started, but anyone can make that folder at any time, and it has no state file of its own to be found first.
    if ($path -eq $LegacyStatePath -and -not ([Usbless.StateFolder]::IsTrusted((Split-Path $path -Parent)) -and [Usbless.StateFolder]::IsTrusted($path))) {
        Write-Log "Ignoring $path, because usbless can't trust who made it."
        return
    }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { Write-Log "Ignoring a damaged state file: $($_.Exception.Message)" }
}
