# --- Disk ----------------------------------------------------------------

function Get-WindowsPartition {
    Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
}

# Unallocated space directly after a partition, C: unless told otherwise, for example where another Linux used to be.
function Get-TailFree($Partition) {
    $c = if ($Partition) { $Partition } else { Get-WindowsPartition }
    $end = $c.Offset + $c.Size
    $next = Get-Partition -DiskNumber $c.DiskNumber | Where-Object Offset -gt $c.Offset | Sort-Object Offset | Select-Object -First 1
    $limit = if ($next) { $next.Offset } else { (Get-Disk -Number $c.DiskNumber).Size - 2MB }   # GPT keeps a backup at the end
    [math]::Max([int64]0, [int64]($limit - $end))
}

function Get-SpaceInfo([string]$Target) {
    $place = Resolve-Target $Target
    $c = $place.Partition
    if ($place.Kind -eq 'gap') {
        return [pscustomobject]@{
            Partition = $c; MinSize = [int64]0; TailFree = [int64]$place.Gap.Size; Reserve = [int64]0
            UsableGB = [int][math]::Floor($place.Gap.Size / 1GB); Kind = 'gap'; Name = 'that free space'; Letter = ''
        }
    }
    $supported = Get-SupportedSize $c
    $tail = Get-TailFree $c
    $reserve = if ($place.IsWindows) { $WindowsReserve } else { $DataReserve }
    $letter = Get-LetterOf $c
    [pscustomobject]@{
        Partition = $c
        MinSize   = [int64]$supported.SizeMin
        TailFree  = $tail
        Reserve   = [int64]$reserve
        # GB Linux can get: free space after the drive, plus what it can give up while keeping its reserve.
        UsableGB  = [int][math]::Floor(($tail + $c.Size - $supported.SizeMin - $reserve) / 1GB)
        Kind      = 'volume'
        Name      = "$letter`:"
        Letter    = $letter
    }
}

# GB that a drive could spare but Windows can't release. Files it can't move, such as the paging
# file, stop a shrink wherever they sit, so a drive with plenty free can still give up very little.
function Get-StuckGB([int64]$FreeBytes, $Space, [int64]$Reserve = $WindowsReserve) {
    $spareGB = [math]::Floor(($FreeBytes - $Reserve) / 1GB)
    $shrinkGB = $Space.UsableGB - [math]::Floor($Space.TailFree / 1GB)
    [int][math]::Max(0, $spareGB - [math]::Max(0, $shrinkGB))
}

$ShrinkAdvice = "open usbless again and click Make room, which clears what's in the way."

# $LiveGB is the second partition, straight after the installer, for a system whose live image FAT32 can't hold.
function Get-Plan([int]$LinuxGB, [int]$InstallerGB, [string]$Target, [int]$LiveGB = 0) {
    $space = Get-SpaceInfo $Target
    $drive = if ($space.Name) { $space.Name } else { 'C:' }
    $maxLinux = $space.UsableGB - $InstallerGB - $LiveGB
    # Replacing Windows only needs the installer: Linux gets the disk once it's been erased.
    if ($LinuxGB -eq 0 -and $maxLinux -lt 0) {
        if ($space.Kind -eq 'gap') { throw "That free space is too small for the installer. It needs $(-$maxLinux) GB more. Choose another drive." }
        throw "Windows can't release enough space from $drive for the installer. It needs $(-$maxLinux) GB more. If $drive is nearly full, delete some files. If it has plenty free, $ShrinkAdvice"
    }
    if ($LinuxGB -gt $maxLinux) {
        if ($space.Kind -eq 'gap') { throw "That free space is too small for $LinuxGB GB of Linux and its installer. Lower the Linux size to $maxLinux GB or less, or choose another drive." }
        if ($maxLinux -lt $MinLinuxGB) { throw "Windows can't release enough space from $drive. It needs $($MinLinuxGB - $maxLinux) GB more. If $drive is nearly full, delete some files. If it has plenty free, $ShrinkAdvice" }
        throw "Windows can't release enough space from $drive for $LinuxGB GB. Lower the Linux size to $maxLinux GB or less and click Install again."
    }
    # Linux goes last and the installer straight before it, at the end of the drive and the free
    # space after it. So the installer's space, and anything left over, stays next to the drive,
    # which is the only place Windows can use it once Linux is installed. The drive only shrinks
    # when the free space isn't enough.
    $c = $space.Partition
    $windowsEnd = [int64]($c.Offset + $c.Size)
    $regionEnd = [int64]([math]::Floor(($windowsEnd + $space.TailFree) / 1MB) * 1MB)
    $linuxStart = [int64]($regionEnd - [int64]$LinuxGB * 1GB)
    $installerOffset = [int64]($linuxStart - [int64]($InstallerGB + $LiveGB) * 1GB)
    $shrink = $installerOffset -lt $windowsEnd
    [pscustomobject]@{
        DiskNumber      = $c.DiskNumber
        PartitionNumber = $c.PartitionNumber
        Shrink          = $shrink
        NewWindowsSize  = if ($shrink) { [int64]($installerOffset - $c.Offset) } else { [int64]$c.Size }
        FreeStart       = $linuxStart
        LinuxGB         = $LinuxGB
        InstallerOffset = $installerOffset
        InstallerSize   = [int64]$InstallerGB * 1GB
        LiveOffset      = [int64]($installerOffset + [int64]$InstallerGB * 1GB)
        LiveSize        = [int64]$LiveGB * 1GB
        TargetOffset    = [int64]$c.Offset
        TargetSize      = [int64]$c.Size
        Kind            = if ($space.Kind) { $space.Kind } else { 'volume' }
        Letter          = $space.Letter
    }
}

function Get-DriveLetter($Partition) {
    for ($i = 0; $i -lt 20; $i++) {
        $letter = (Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber).DriveLetter
        if ($letter -and $letter -ne [char]0) { return [string]$letter }
        # Asking while Windows is already on it fails harmlessly.
        if ($i % 4 -eq 0) { try { Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AssignDriveLetter } catch { } }
        Start-Sleep -Milliseconds 500
    }
    throw 'Windows did not give the installer partition a drive letter. If every letter is in use, remove a network drive or USB drive and try again.'
}

# Partition numbers can shift once a partition is removed, and acting on a stale one could
# delete Windows' recovery partition. So each is looked up again by where it starts.
function Get-PartitionAt([int]$DiskNumber, [int64]$Offset) {
    Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object { [int64]$_.Offset -eq $Offset } | Select-Object -First 1
}

function Remove-PartitionAt([int]$DiskNumber, [int64]$Offset) {
    $partition = Get-PartitionAt $DiskNumber $Offset
    if (-not $partition) { return }
    if ($partition.IsSystem -or $partition.IsBoot) { throw "Refusing to remove partition $($partition.PartitionNumber): Windows needs it to start." }
    Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
}

function Remove-DriveLetter($Partition) {
    $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
    if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) {
        Remove-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath "$($p.DriveLetter):\"
    }
}

function Format-NewPartition($Partition, [string]$FileSystem, [string]$Label) {
    Format-Volume -Partition $Partition -FileSystem $FileSystem -NewFileSystemLabel $Label -Confirm:$false -Force | Out-Null
}

# Written down first, so a crash straight after making it can't leave one nothing knows about. It's
# only ever acted on if a blank partition is really there: see Get-RecordedPartitions.
function New-RecordedPartition($Plan, $State, [string]$Role, [int64]$Offset, [int64]$Size) {
    $record = [pscustomobject]@{ Role = $Role; Offset = $Offset; Size = $Size }
    $State.Partitions += $record
    Save-State $State
    $partition = New-Partition -DiskNumber $Plan.DiskNumber -Offset $Offset -Size $Size
    $record.Offset = $partition.Offset
    $record.Size = $partition.Size
    Save-State $State
    $partition
}

function New-LinuxSpace($Plan, [string]$Strategy, $State) {
    if ($Plan.Shrink) {
        $letter = if ($Plan.Letter) { $Plan.Letter } else { 'C' }
        $what = if ($letter -eq $env:SystemDrive.TrimEnd(':')) { 'Windows' } else { "drive $letter`:" }
        Set-Status ('Shrinking {0} to {1:N0} GB to make room (can take a few minutes)...' -f $what, ($Plan.NewWindowsSize / 1GB))
        # The size it was, because a crash can come after the shrink and before saying it happened. See Invoke-Cleanup.
        $State | Add-Member -NotePropertyName SizeBeforeShrink -NotePropertyValue $Plan.TargetSize -Force
        Save-State $State
        try {
            Resize-Partition -DiskNumber $Plan.DiskNumber -PartitionNumber $Plan.PartitionNumber -Size $Plan.NewWindowsSize
        } catch {
            # Hibernation, paging and restore point files can't be moved, so they limit the shrink.
            throw "Windows could not shrink $letter`: that far ($($_.Exception.Message)). Try a smaller Linux size. If that doesn't help, $ShrinkAdvice"
        }
        $State.WindowsShrunk = $true
        Save-State $State
    } else {
        Write-Log 'Using free space; the drive next to it keeps its size.'
    }

    if ($Strategy -eq 'prepared') {
        Set-Status 'Creating the Linux partitions...'
        $boot = New-RecordedPartition $Plan $State 'boot' $Plan.FreeStart 1GB
        Format-NewPartition $boot FAT32 $BootLabel
        Remove-DriveLetter $boot

        $root = New-RecordedPartition $Plan $State 'root' ($Plan.FreeStart + 1GB) ([int64]($Plan.LinuxGB - 1) * 1GB)
        # A placeholder file system: it gives the partition a recognisable label in the
        # Linux installer and stops Windows offering to format a blank partition.
        # The installer replaces it with ext4.
        Format-NewPartition $root exFAT $RootLabel
        Remove-DriveLetter $root
    }

    if ($Plan.LiveSize) {
        Set-Status 'Creating the partition for the live system...'
        $live = New-RecordedPartition $Plan $State 'live' $Plan.LiveOffset $Plan.LiveSize
        Format-NewPartition $live exFAT $LiveLabel
    }

    Set-Status 'Creating the installer partition...'
    $installer = New-RecordedPartition $Plan $State 'installer' $Plan.InstallerOffset $Plan.InstallerSize
    Format-NewPartition $installer FAT32 $InstallerLabel
    $installer
}

# Runs robocopy, showing how far it's got from how much room is left on the drive it's filling.
function Invoke-CopyWatched([string[]]$Arguments, [string]$Target, [int64]$Total, [string]$What) {
    $startFree = (Get-Volume -DriveLetter $Target).SizeRemaining
    $proc = Start-Process -FilePath robocopy.exe -PassThru -WindowStyle Hidden -ArgumentList $Arguments
    $null = $proc.Handle
    $pollFailed = $false
    try {
        while (-not $proc.HasExited) {
            # Only the progress: not being able to read it says nothing about the copy.
            try {
                $copied = $startFree - (Get-Volume -DriveLetter $Target).SizeRemaining
                $Sync.Status = 'Copying {0}... {1:N1} of {2:N1} GB' -f $What, ($copied / 1GB), ($Total / 1GB)
                Set-ByteProgress ([math]::Max([int64]0, [int64]$copied)) $Total
            } catch {
                if (-not $pollFailed) { Write-Log "Could not read how far the copy has got: $($_.Exception.Message)" }
                $pollFailed = $true
            }
            Start-Sleep -Milliseconds 700
        }
    } finally {
        # Being stopped mustn't leave it writing to a partition that's about to be removed.
        if (-not $proc.HasExited) {
            $proc.Kill()
            [void]$proc.WaitForExit(10000)
        }
    }
    if ($proc.ExitCode -ge 8) { throw "Copying $What failed (robocopy code $($proc.ExitCode))." }
}

# The files that went on the second partition instead of the installer's, where the ISO has them.
function Copy-LiveFiles($Iso, [string]$Target) {
    $sourceRoot = "$($Iso.Letter):\"
    $targetRoot = "$Target`:\"
    $folder = Split-Path $Iso.LiveFiles[0].FullName.Substring($sourceRoot.Length) -Parent
    $names = @($Iso.LiveFiles | ForEach-Object { $_.Name })
    Invoke-CopyWatched (@((Join-Path $sourceRoot $folder), (Join-Path $targetRoot $folder)) + $names + @('/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')) $Target $Iso.LiveBytes 'the live system'
    foreach ($file in $Iso.LiveFiles) {
        $copy = Get-Item -LiteralPath (Join-Path $targetRoot $file.FullName.Substring($sourceRoot.Length)) -Force -ErrorAction SilentlyContinue
        if (-not $copy -or $copy.Length -ne $file.Length) { throw "$($file.Name) did not copy to the second installer partition." }
    }
    Write-Log 'Live system copied and checked.'
}

function Copy-Installer($Iso, [string]$Target) {
    # robocopy instead of Copy-Item: it keeps hidden folders like .disk that the live system needs.
    $arguments = @("$($Iso.Letter):\", "$Target`:\", '/E', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $live = @($Iso.LiveFiles | Where-Object { $_ } | ForEach-Object { $_.FullName })
    if ($live.Count) { $arguments += @('/XF') + $live }
    Invoke-CopyWatched $arguments $Target $Iso.Bytes 'the installer'

    # Check file by file. Comparing totals doesn't work: Windows adds its own
    # "System Volume Information" folder to every drive with a letter.
    $sourceRoot = "$($Iso.Letter):\"
    $targetRoot = "$Target`:\"
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File) {
        if ($file.FullName -in $live) { continue }
        $relative = $file.FullName.Substring($sourceRoot.Length)
        $copy = Get-Item -LiteralPath (Join-Path $targetRoot $relative) -Force -ErrorAction SilentlyContinue
        if (-not $copy -or $copy.Length -ne $file.Length) { $missing.Add($relative) }
    }
    if ($missing.Count) {
        foreach ($name in $missing) { Write-Log "Not copied: $name" }
        throw "$($missing.Count) installer file(s) did not copy, for example $($missing[0]). The full list is under Show details."
    }
    Write-Log 'Installer files copied and checked.'
    # Offline packages are a convenience: a problem here must not cost a finished copy.
    try { Repair-ShortenedNames $targetRoot } catch { Write-Log "Could not check package names: $($_.Exception.Message)" }
}

# The files the ISO's package indexes say it has, as paths from its root.
function Get-PackagePaths([string]$Root) {
    $dists = Join-Path $Root 'dists'
    if (-not (Test-Path -LiteralPath $dists)) { return }
    $indexes = Get-ChildItem -LiteralPath $dists -Recurse -Force -File | Where-Object { $_.Name -in @('Packages', 'Packages.gz') }
    $paths = foreach ($index in $indexes) {
        $stream = [IO.File]::OpenRead($index.FullName)
        try {
            $input_ = if ($index.Extension -eq '.gz') { New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Decompress) } else { $stream }
            $text = (New-Object IO.StreamReader($input_)).ReadToEnd()
        } finally { $stream.Dispose() }
        [regex]::Matches($text, '(?m)^Filename:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value -replace '^\./', '' }
    }
    $paths | Sort-Object -Unique
}

# Windows reads an ISO through its Joliet names, which stop at 103 characters, so a very
# long package name arrives shortened (Pop!_OS has two). The indexes still use the real
# name, which FAT32 can hold, so the installer wouldn't find the file until it is renamed.
function Repair-ShortenedNames([string]$Root) {
    $known = @(Get-PackagePaths $Root)
    foreach ($relative in $known) {
        $path = Join-Path $Root ($relative -replace '/', '\')
        if (Test-Path -LiteralPath $path) { continue }
        $folder = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $name = Split-Path $path -Leaf
        $extension = [IO.Path]::GetExtension($name)
        $matches_ = @(Get-ChildItem -LiteralPath $folder -Force -File | Where-Object {
                $_.Extension -eq $extension -and $name.StartsWith($_.BaseName) -and $_.BaseName.Length -ge 40 -and
                (($relative.Substring(0, $relative.Length - $name.Length) + $_.Name) -notin $known)
            })
        # More than one candidate would be a guess.
        if ($matches_.Count -eq 1) {
            Rename-Item -LiteralPath $matches_[0].FullName -NewName $name
            Write-Log "Restored the full name of $name."
        }
    }
}
