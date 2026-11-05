# --- Another Linux on this PC (for example Pond) ---------------------------

$LinuxPartitionTypes = @(
    '{0fc63daf-8483-4772-8e79-3d69d8477de4}'   # Linux file system
    '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}'   # Linux root (x86-64)
    '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}'   # Linux /home
    '{3b8f8425-20e0-4f3b-907f-1a25a76f98e8}'   # Linux /srv
    '{bc13c2ff-59e6-4262-a352-b275fd6f7172}'   # Linux /boot (XBOOTLDR)
    '{0657fd6d-a4ab-43c4-84e5-0933c84b4f4f}'   # Linux swap
    '{e6d6d379-f507-44c2-a23c-238f2a3df928}'   # Linux LVM
    '{a19d880f-05fc-4d3b-a006-743f0f84911e}'   # Linux RAID
)

$LinuxLoaderPattern = '(shim|grub|systemd-boot|refind|limine)[^\\]*\.efi$'

# The partitions a Linux on these disks might start from, including an EFI partition on another
# disk. Whichever else is named, the Windows disk counts, since Linux Mint starts from there.
function Get-DiskGuids([object[]]$Disks) {
    foreach ($disk in @(@($Disks) + (Get-WindowsPartition).DiskNumber | Where-Object { $null -ne $_ } | Sort-Object -Unique)) {
        Get-Partition -DiskNumber $disk -ErrorAction SilentlyContinue | ForEach-Object { $_.Guid }
    }
    try { (Get-WindowsEsp).Guid } catch { }
}

# Startup entries for a Linux boot loader on these disks, other than usbless's own.
function Get-LinuxLoaders([object[]]$Disks) {
    $onDisk = @(Get-DiskGuids $Disks)
    $entries = @(try { [Usbless.Firmware]::ListEntries() } catch { Write-Log "Could not read startup entries: $($_.Exception.Message)" })
    @($entries | Where-Object {
            $_.PartitionGuid -and $onDisk -contains $_.PartitionGuid -and $_.Path -and
            $_.Path -notlike '\EFI\Microsoft\*' -and $_.Description -notmatch $EntryPattern -and
            $_.Path -match $LinuxLoaderPattern
        })
}

function Get-LinuxPartitions($Partitions) {
    $linux = @($Partitions | Where-Object { $_.GptType -in $LinuxPartitionTypes })
    # Installers that run on Windows (Pond's does) may leave the generic "basic data" type on
    # their partitions, so also look at what is actually on those with no drive letter.
    $linux += @($Partitions | Where-Object {
            $_.GptType -eq $BasicDataType -and (-not $_.DriveLetter -or $_.DriveLetter -eq [char]0) -and $linux.Guid -notcontains $_.Guid -and
            (Test-LinuxSignature $_)
        })
    $linux
}

# Another Linux on the Windows disk, or on a disk where usbless put it.
function Get-OtherSystem {
    $windowsDisk = (Get-WindowsPartition).DiskNumber
    $known = @(Get-LinuxDisks)
    $disks = @($windowsDisk) + @(Get-Disk | Where-Object { $_.Number -ne $windowsDisk -and $known -contains $_.Guid } | ForEach-Object { $_.Number })
    foreach ($disk in $disks) {
        $found = Find-OtherSystem $disk
        if ($found) { return $found }
    }
}

# Whether a Linux usbless isn't removing could be somewhere else, on another disk or one that's unplugged.
function Test-LinuxElsewhere([int]$Disk) {
    $guid = (Get-Disk -Number $Disk).Guid
    if (@(Get-LinuxDisks | Where-Object { $_ -ne $guid }).Count) { return $true }
    foreach ($other in @(Get-Disk | Where-Object Number -ne $Disk)) {
        if (@(Get-LinuxPartitions @(Get-Partition -DiskNumber $other.Number -ErrorAction SilentlyContinue)).Count) { return $true }
    }
    $false
}

function Get-FileSystemUuid($Partition) {
    try { [Usbless.DiskProbe]::ReadUuid($Partition.DiskNumber, [int64]$Partition.Offset) } catch { $null }
}

# The IDs each loader folder's small grub.cfg names: that's how GRUB finds the Linux it belongs to.
function Read-EspLoaderIds([string]$Root, [string[]]$Folders) {
    $ids = @{}
    foreach ($folder in $Folders) {
        $config = Join-Path $Root "EFI\$folder\grub.cfg"
        if (Test-Path -LiteralPath $config) {
            $ids[$folder] = @([regex]::Matches((Read-BootConfig $config), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value })
        }
    }
    $ids
}

# Which of these folders on Windows' EFI partition belong to the Linux on $Linux. Any of them can, if
# there's no other Linux for them to belong to. Otherwise only one that names it does. Linux Mint on
# a second disk keeps its loader there too, so one that can't be tied to this system isn't its to take.
function Get-OwnedEspFolders([string[]]$Folders, $Linux, [int]$Disk) {
    if (-not $Folders) { return }
    if (-not (Test-LinuxElsewhere $Disk)) { return $Folders }
    $mine = @($Linux | ForEach-Object { Get-FileSystemUuid $_ } | Where-Object { $_ })
    $ids = try { Use-Esp { param($root) Read-EspLoaderIds $root $Folders } } catch { Write-Log "Could not read the EFI system partition: $($_.Exception.Message)"; @{} }
    foreach ($folder in $Folders) {
        if (@($ids[$folder] | Where-Object { $_ -in $mine }).Count) { $folder }
    }
}

# Linux partitions on a disk, the startup entries tied to them, and a separate EFI partition if that
# Linux made its own. Windows' EFI partition is never included. Kept names the startup entries there
# that can't be tied to this Linux, which stay.
function Find-OtherSystem([int]$Disk) {
    $partitions = @(Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue)
    $state = Read-State
    $casper = if ($state) { @(Get-CasperPartition $state $partitions | ForEach-Object { $_.Guid }) } else { @() }
    $linux = @(Get-LinuxPartitions $partitions | Where-Object { $_.Guid -notin $casper })
    if (-not $linux.Count) { return $null }
    $removing = @($linux | ForEach-Object { $_.Guid })

    $entries = @(try { Get-BootEntries } catch { Write-Log "Could not read startup entries: $($_.Exception.Message)" })
    $microsoft = @($entries | Where-Object { $_.Path -like '\EFI\Microsoft\*' } | ForEach-Object { $_.PartitionGuid })
    $windowsEsp = try { (Get-WindowsEsp).Guid } catch { $null }
    $own = @($partitions | Where-Object { $_.GptType -eq $EspType -and $_.Guid -ne $windowsEsp -and $_.Guid -notin $microsoft } | ForEach-Object { $_.Guid })
    $others = @($entries | Where-Object { $_.PartitionGuid -and $_.Path -and $_.Path -notlike '\EFI\Microsoft\*' -and $_.Description -notmatch $EntryPattern })

    $shared = @($others | Where-Object { $_.PartitionGuid -eq $windowsEsp -and $_.Path -match $LinuxLoaderPattern })
    $owned = @(Get-OwnedEspFolders @($shared | ForEach-Object { ($_.Path -split '\\')[2] } | Sort-Object -Unique) $linux $Disk)
    $boot = @($others | Where-Object {
            $removing -contains $_.PartitionGuid -or ($own -contains $_.PartitionGuid -and $_.Path -match $LinuxLoaderPattern) -or
            ($_.PartitionGuid -eq $windowsEsp -and $_.Path -match $LinuxLoaderPattern -and $owned -contains ($_.Path -split '\\')[2])
        })
    $kept = @($shared | Where-Object { $owned -notcontains ($_.Path -split '\\')[2] } | ForEach-Object { $_.Description } | Select-Object -Unique)

    # Only when Windows' own EFI partition is known for certain, so it can never be picked.
    $esps = if (-not $microsoft.Count) { @() } else {
        @($partitions | Where-Object { $own -contains $_.Guid -and ($boot | Where-Object PartitionGuid -eq $_.Guid) })
    }

    $name = ($boot | Select-Object -First 1).Description
    if (-not $name) { $name = 'the other Linux' }
    $all = @($linux) + @($esps)
    [pscustomobject]@{
        Name       = $name
        SizeGB     = [int][math]::Round((($all | Measure-Object -Property Size -Sum).Sum) / 1GB)
        Partitions = $all
        Entries    = $boot
        Kept       = $kept
        WindowsEsp = $windowsEsp
        OnWindowsDisk = $Disk -eq (Get-WindowsPartition).DiskNumber
        DiskGuid   = (Get-Disk -Number $Disk).Guid
    }
}

# True only when the partition's own first bytes say it holds a Linux file system. Being
# unreadable to Windows isn't enough: a locked BitLocker drive is unreadable too.
function Test-LinuxSignature($Partition) {
    if ($Partition.IsSystem -or $Partition.IsBoot) { return $false }
    $found = try { [Usbless.DiskProbe]::ReadSignature($Partition.DiskNumber, [int64]$Partition.Offset) } catch {
        Write-Log "Could not read partition $($Partition.PartitionNumber): $($_.Exception.Message)"
        $null
    }
    $found -in $LinuxSignatures
}

function Invoke-Diskpart([string[]]$Commands) {
    $ErrorActionPreference = 'Continue'
    $Commands | & diskpart.exe 2>&1 | Out-String
}

# Only on the disk it was found on: a cloned disk can have the same GUIDs.
function Remove-PartitionByGuid([string]$Guid, [int]$DiskNumber) {
    $partition = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object Guid -eq $Guid | Select-Object -First 1
    if (-not $partition) { return }
    try {
        Remove-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
        return
    } catch { }
    # Windows protects EFI partitions; diskpart can still delete one that isn't Windows' own.
    # On its input, because a script in the temp folder could be changed by anything this user runs.
    $output = Invoke-Diskpart @("select disk $($partition.DiskNumber)", "select partition $($partition.PartitionNumber)", 'delete partition override', 'exit')
    # This way diskpart doesn't report failure in its exit code, so what counts is whether it's gone. Windows can take a moment to notice.
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Get-Partition -DiskNumber $partition.DiskNumber -ErrorAction SilentlyContinue | Where-Object Guid -eq $Guid)) { return }
        Start-Sleep -Seconds 1
    }
    throw "Could not delete partition $($partition.PartitionNumber): $output"
}

function Remove-OtherSystem {
    $other = Get-OtherSystem
    if (-not $other) { throw 'There is no other Linux on this drive.' }
    Set-Status "Removing $($other.Name)..."
    foreach ($name in @($other.Kept)) { if ($name) { Write-Log "Kept the startup entry for $name, which usbless can't tie to this Linux." } }

    foreach ($entry in $other.Entries) {
        [Usbless.Firmware]::DeleteBootEntry($entry.Number)
        Write-Log ('Removed startup entry Boot{0:X4} ({1}).' -f $entry.Number, $entry.Description)
    }

    # Its boot loader files on Windows' EFI partition, e.g. \EFI\pond.
    $folders = @($other.Entries | Where-Object { $_.PartitionGuid -eq $other.WindowsEsp } |
        ForEach-Object { ($_.Path -split '\\')[2] } | Where-Object { $_ -and $_ -notin @('Microsoft', 'Boot') } | Sort-Object -Unique)
    if ($folders.Count) {
        Use-Esp {
            param($root)
            foreach ($folder in $folders) {
                $path = Join-Path $root "EFI\$folder"
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Log "Removed \EFI\$folder." }
            }
        }
    }

    foreach ($partition in $other.Partitions) {
        Set-Status "Removing $($other.Name) ($([math]::Round($partition.Size / 1GB)) GB partition)..."
        Remove-PartitionByGuid $partition.Guid $partition.DiskNumber
    }
    if (-not $other.OnWindowsDisk) { Set-LinuxDisks (@(Get-LinuxDisks) | Where-Object { $_ -ne $other.DiskGuid }) }
    Set-Status "$($other.Name) removed." 100
}

# Gives the free space right after a drive, C: unless told otherwise, to that drive.
function Expand-Windows([string]$Target) {
    $c = (Resolve-Target $Target).Partition
    $letter = Get-LetterOf $c
    $max = (Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber).SizeMax
    if ($max -le $c.Size + 1MB) { throw "The free space isn't next to drive $letter`:, so Windows can't use it directly." }
    Set-Status "Giving the space to drive $letter`:..."
    Resize-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -Size $max
    Set-Status 'Done.' 100
}
