# Unit tests for putting Linux on any drive. Like Engine.Tests.ps1, everything that touches the
# disk or the firmware is mocked. tests/Probe-VirtualDisks.ps1 runs the same code on real partitions.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1') -WithUsbless
    Mock Write-Log { }
    Mock Get-DiskAttachment { 'internal' }

    function New-TestDisk([int]$Number = 1, [string]$Bus = 'SATA', [string]$Style = 'GPT') {
        [pscustomobject]@{
            Number = $Number; BusType = $Bus; PartitionStyle = $Style; FriendlyName = 'WD  Blue'; Size = [int64]1000GB; Guid = "{disk-$Number}"
            IsOffline = $false; IsReadOnly = $false; IsClustered = $false; HealthStatus = 'Healthy'
        }
    }
    function New-TestPartition([string]$Letter = 'D', [int64]$Offset = 1GB, [int64]$Size = 500GB, [string]$Type = $BasicDataType, [int]$Disk = 1) {
        [pscustomobject]@{
            DiskNumber = $Disk; PartitionNumber = 2; Offset = $Offset; Size = $Size; GptType = $Type; Guid = "{part-$Offset}"
            DriveLetter = if ($Letter) { [char]$Letter } else { [char]0 }; IsSystem = $false; IsBoot = $false; IsHidden = $false
        }
    }
}

Describe 'Get-DriveBlocker' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Partition { }
        Mock Get-LinuxPartitions { }
        Mock Test-HoldsWindows { $false }
        Mock Test-BitLockerChanging { $false }
        Mock Get-PartitionSignature { $null }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy' } }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*winre.wim' }
    }
    It 'takes an NTFS data volume on an internal disk' {
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeNullOrEmpty
    }
    It 'takes free space on an internal disk' {
        Get-DriveBlocker (New-TestDisk) $null | Should -BeNullOrEmpty
    }
    It 'takes every kind of internal disk' -ForEach @(@{ bus = 'NVMe' }, @{ bus = 'SATA' }, @{ bus = 'SAS' }, @{ bus = 'ATA' }, @{ bus = 'SCSI' }) {
        Get-DriveBlocker (New-TestDisk -Bus $bus) $null | Should -BeNullOrEmpty
    }
    It 'refuses a <bus> disk' -ForEach @(
        @{ bus = 'USB'; says = '*USB*' }, @{ bus = 'SD'; says = '*removable*' }, @{ bus = 'MMC'; says = '*removable*' }, @{ bus = 'iSCSI'; says = '*network*' }
        @{ bus = 'File Backed Virtual'; says = '*virtual*' }, @{ bus = 'Spaces'; says = '*Storage Spaces*' }, @{ bus = 'RAID'; says = '*RAID*' }
    ) {
        Get-DriveBlocker (New-TestDisk -Bus $bus) $null | Should -BeLike $says
    }
    It 'refuses an NVMe disk Windows expects to be unplugged, as a Thunderbolt enclosure is' {
        Mock Get-DiskAttachment { 'external' }
        Get-DriveBlocker (New-TestDisk -Bus 'NVMe') $null | Should -BeLike '*Thunderbolt or USB4*inside this PC*'
    }
    It 'refuses a disk when it cannot tell where it is' {
        Mock Get-DiskAttachment { 'unclear' }
        Get-DriveBlocker (New-TestDisk -Bus 'NVMe') $null | Should -BeLike "*can't tell*inside this PC*"
    }
    It 'keeps Windows'' own disk, however it is attached' {
        Mock Get-DiskAttachment { 'external' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 1 } }
        Get-DriveBlocker (New-TestDisk -Number 1 -Bus 'NVMe') $null | Should -BeNullOrEmpty
        Get-DriveBlocker (New-TestDisk -Number 0 -Bus 'NVMe') $null -Windows | Should -BeNullOrEmpty
        Should -Invoke Get-DiskAttachment -Times 0 -Exactly
    }
    It 'refuses an MBR disk' {
        Get-DriveBlocker (New-TestDisk -Style 'MBR') $null | Should -BeLike '*MBR*'
    }
    It 'says what to do with a disk that has never been set up' {
        Get-DriveBlocker (New-TestDisk -Style 'RAW') $null | Should -BeLike '*Disk Management*'
    }
    It 'refuses a disk that is <why>' -ForEach @(
        @{ why = 'offline'; name = 'IsOffline'; value = $true }
        @{ why = 'read-only'; name = 'IsReadOnly'; value = $true }
        @{ why = 'cluster'; name = 'IsClustered'; value = $true }
        @{ why = 'problem'; name = 'HealthStatus'; value = 'Unhealthy' }
    ) {
        $disk = New-TestDisk
        $disk.$name = $value
        Get-DriveBlocker $disk $null | Should -BeLike "*$why*"
    }
    It 'refuses a dynamic disk' {
        Mock Get-Partition { New-TestPartition -Type $DynamicDiskTypes[1] }
        Get-DriveBlocker (New-TestDisk) $null | Should -BeLike '*dynamic*'
    }
    It 'refuses a second disk with another Windows on it' {
        Mock Get-Partition { New-TestPartition }
        Mock Test-HoldsWindows { $true }
        Get-DriveBlocker (New-TestDisk) $null | Should -BeLike '*another copy of Windows*'
    }
    It 'refuses a second disk that already has Linux on it' {
        Mock Get-LinuxPartitions { New-TestPartition }
        Get-DriveBlocker (New-TestDisk) $null | Should -BeLike '*already has Linux*'
    }
    It 'refuses Windows'' recovery partition, whatever its letter' {
        Get-DriveBlocker (New-TestDisk) (New-TestPartition -Type $RecoveryType) | Should -BeLike "*recovery partition*"
    }
    It 'refuses an EFI partition' {
        Get-DriveBlocker (New-TestDisk) (New-TestPartition -Type $EspType) | Should -BeLike '*system partition*'
    }
    It 'refuses a volume holding Windows'' recovery files' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*winre.wim' }
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeLike "*recovery files*"
    }
    It 'refuses a locked BitLocker drive and says how to unlock it, even with no letter' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'Unknown'; HealthStatus = 'Healthy' } }
        Mock Get-PartitionSignature { 'bitlocker' }
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeLike '*locked with BitLocker*File Explorer*'
        Get-DriveBlocker (New-TestDisk) (New-TestPartition -Letter '') | Should -BeLike '*locked with BitLocker*'
    }
    It 'takes an unlocked BitLocker drive' {
        Mock Get-PartitionSignature { 'bitlocker' }
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeNullOrEmpty
    }
    It 'waits for BitLocker to finish encrypting' {
        Mock Test-BitLockerChanging { $true }
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeLike '*encrypted or decrypted*'
    }
    It 'refuses a volume with no letter' {
        Get-DriveBlocker (New-TestDisk) (New-TestPartition -Letter '') | Should -BeLike '*no drive letter*'
    }
    It 'refuses a volume that is not NTFS, and names the format' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'exFAT'; HealthStatus = 'Healthy' } }
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeLike 'Drive D: uses exFAT*'
    }
    It 'refuses a damaged volume and names the right drive' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Unhealthy' } }
        Get-DriveBlocker (New-TestDisk) (New-TestPartition) | Should -BeLike '*chkdsk D: /f*'
    }
    It 'refuses a data volume on the Windows disk that holds another Windows' {
        Mock Test-HoldsWindows { $true }
        Get-DriveBlocker (New-TestDisk -Number 0) (New-TestPartition -Disk 0) | Should -BeLike '*another copy of Windows*'
    }

    Context 'on the Windows disk' {
        It 'only warns about RAID, as it does for C:' {
            Get-DriveBlocker (New-TestDisk -Number 0 -Bus 'RAID') (New-TestPartition -Disk 0) | Should -BeNullOrEmpty
        }
        It 'does not mind another Linux, which usbless can offer to remove' {
            Mock Get-LinuxPartitions { New-TestPartition }
            Get-DriveBlocker (New-TestDisk -Number 0) $null | Should -BeNullOrEmpty
        }
        It 'keeps the old words for MBR' {
            Get-DriveBlocker (New-TestDisk -Number 0 -Style 'MBR') $null | Should -BeLike 'The Windows disk uses*'
        }
        It 'treats C: as it always has, with no checks meant for data volumes' {
            $c = New-TestPartition -Letter 'C' -Disk 0 -Type $RecoveryType
            Get-DriveBlocker (New-TestDisk -Number 0 -Bus 'USB') $c -Windows | Should -BeNullOrEmpty
            Should -Invoke Test-HoldsWindows -Times 0
        }
        It 'keeps every check C: has always had' -ForEach @(
            @{ style = 'MBR'; bus = 'SATA'; fs = 'NTFS'; health = 'Healthy'; says = '*MBR*' }
            @{ style = 'GPT'; bus = 'Spaces'; fs = 'NTFS'; health = 'Healthy'; says = '*Storage Spaces*' }
            @{ style = 'GPT'; bus = 'File Backed Virtual'; fs = 'NTFS'; health = 'Healthy'; says = '*virtual disk*' }
            @{ style = 'GPT'; bus = 'NVMe'; fs = 'ReFS'; health = 'Healthy'; says = 'Drive C: uses ReFS*' }
            @{ style = 'GPT'; bus = 'NVMe'; fs = 'NTFS'; health = 'Warning'; says = '*chkdsk C:*' }
        ) {
            Mock Get-Volume { [pscustomobject]@{ FileSystemType = $fs; HealthStatus = $health } }
            Get-DriveBlocker (New-TestDisk -Number 0 -Bus $bus -Style $style) (New-TestPartition -Letter 'C' -Disk 0) -Windows | Should -BeLike $says
        }
    }
}

Describe 'Get-DiskGaps' {
    It 'finds free space between, before and after partitions, and says what it follows' {
        $disk = New-TestDisk
        $gaps = @(Get-DiskGaps $disk @((New-TestPartition -Offset ([int64]20GB) -Size ([int64]100GB)), (New-TestPartition -Offset ([int64]200GB) -Size ([int64]100GB))))
        $gaps.Count | Should -Be 3
        $gaps[0].Offset | Should -Be ([int64]1MB)
        $gaps[0].After | Should -BeNullOrEmpty
        $gaps[1].Offset | Should -Be ([int64]120GB)
        $gaps[1].Size | Should -Be ([int64]80GB)
        $gaps[1].After.Offset | Should -Be ([int64]20GB)
        $gaps[2].Offset + $gaps[2].Size | Should -Be ([int64]1000GB - 2MB)
    }
    It 'sees all of an empty disk' {
        @(Get-DiskGaps (New-TestDisk) @()).Count | Should -Be 1
    }
    It 'ignores slivers' {
        @(Get-DiskGaps (New-TestDisk) @(New-TestPartition -Offset ([int64]5GB) -Size ([int64]992GB))).Count | Should -Be 0
    }
    It 'starts on a megabyte boundary' {
        (Get-DiskGaps (New-TestDisk) @(New-TestPartition -Offset ([int64]1MB) -Size ([int64]100GB + 512)))[0].Offset % 1MB | Should -Be 0
    }
}

Describe 'Get-DriveTargets' {
    BeforeEach {
        Mock Get-WindowsPartition { New-TestPartition -Letter 'C' -Disk 0 -Offset ([int64]1GB) -Size ([int64]200GB) }
        Mock Get-Disk {
            $all = @((New-TestDisk -Number 0), (New-TestDisk -Number 1), (New-TestDisk -Number 2 -Bus 'USB'))
            if ($null -ne $Number) { $all | Where-Object { $Number -contains $_.Number } } else { $all }
        }
        Mock Get-Partition {
            if ($DiskNumber -contains 0) {
                New-TestPartition -Letter '' -Disk 0 -Offset ([int64]1MB) -Size ([int64]100MB) -Type $EspType
                New-TestPartition -Letter 'C' -Disk 0 -Offset ([int64]1GB) -Size ([int64]200GB)
                New-TestPartition -Letter '' -Disk 0 -Offset ([int64]201GB) -Size ([int64]1GB) -Type $RecoveryType
                New-TestPartition -Letter 'D' -Disk 0 -Offset ([int64]202GB) -Size ([int64]798GB - 2MB)
            } elseif ($DiskNumber -contains 1) {
                New-TestPartition -Letter 'E' -Disk 1 -Offset ([int64]1GB) -Size ([int64]300GB)
            }
        }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy'; Size = [int64]200GB; SizeRemaining = [int64]100GB } }
        Mock Get-LinuxPartitions { }
        Mock Test-HoldsWindows { $false }
        Mock Test-BitLockerChanging { $false }
        Mock Get-PartitionSignature { $null }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*winre.wim' }
    }
    It 'lists C: first, then the rest of its disk, then other disks' {
        $rows = @(Get-DriveTargets)
        ($rows.Title -join ',') | Should -Be 'Drive C:,Drive D:,Drive E:,WD Blue'
        $rows[0].Id | Should -Be ''
    }
    It 'never lists the EFI or recovery partitions as something to shrink' {
        @(Get-DriveTargets | Where-Object Kind -eq 'volume').Count | Should -Be 3
    }
    It 'folds free space after a volume into that volume' {
        $e = @(Get-DriveTargets) | Where-Object Letter -eq 'E'
        $e.TailFreeGB | Should -Be 698
        $e.UsableGB | Should -Be (698 + 98)
        @(Get-DriveTargets | Where-Object Kind -eq 'gap').Count | Should -Be 0
    }
    It 'keeps less back on a data drive than on C:' {
        $rows = @(Get-DriveTargets)
        $rows[0].UsableGB | Should -Be (100 - 8)
        $rows[1].UsableGB | Should -Be (100 - 2)
    }
    It 'gives a refused disk one row, with its reason' {
        $usb = @(Get-DriveTargets) | Where-Object Kind -eq 'disk'
        $usb.Blocker | Should -BeLike '*USB*'
    }
    It 'lists free space on its own when the volume before it is refused' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'exFAT'; HealthStatus = 'Healthy'; Size = [int64]200GB; SizeRemaining = [int64]100GB } } -ParameterFilter { $DriveLetter -contains 'E' }
        $gap = @(Get-DriveTargets) | Where-Object Kind -eq 'gap'
        $gap.Id | Should -Be "gap:{disk-1}:$([int64]301GB)"
        $gap.UsableGB | Should -Be 698
    }
}

Describe 'Resolve-Target and the plan' {
    BeforeEach {
        Mock Get-Disk { New-TestDisk -Number 3 }
        Mock Get-Partition { New-TestPartition -Letter 'E' -Disk 3 -Offset ([int64]1GB) -Size ([int64]300GB) }
        Mock Get-TailFree { [int64]0 }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMin = [int64]100GB } }
    }
    It 'means C: when nothing is named' {
        Mock Get-WindowsPartition { New-TestPartition -Letter 'C' -Disk 0 }
        (Resolve-Target '').IsWindows | Should -BeTrue
    }
    It 'finds a volume by its disk''s GUID, whatever number that disk has now' {
        (Resolve-Target "volume:{disk-3}:$([int64]1GB)").Partition.DiskNumber | Should -Be 3
    }
    It 'says so when the drive has gone' {
        { Resolve-Target 'volume:{other}:5' } | Should -Throw "*isn't there*"
    }
    It 'plans to shrink another volume, on its own disk' {
        $plan = Get-Plan 60 8 "volume:{disk-3}:$([int64]1GB)"
        $plan.DiskNumber | Should -Be 3
        $plan.Shrink | Should -BeTrue
        $plan.Letter | Should -Be 'E'
        $plan.NewWindowsSize | Should -Be ([int64]232GB)
        $plan.InstallerOffset | Should -Be ([int64]233GB)
        $plan.TargetOffset | Should -Be ([int64]1GB)
    }
    It 'keeps a smaller reserve on another volume' {
        (Get-SpaceInfo "volume:{disk-3}:$([int64]1GB)").UsableGB | Should -Be (200 - 2)
    }
    It 'plans in free space with nothing to shrink, at its end' {
        $plan = Get-Plan 60 8 "gap:{disk-3}:$([int64]301GB)"
        $plan.Kind | Should -Be 'gap'
        $plan.Shrink | Should -BeFalse
        $plan.FreeStart + 60GB | Should -Be ([int64]1000GB - 2MB)
        $plan.InstallerOffset + 8GB | Should -Be $plan.FreeStart
    }
    It 'refuses too much for the free space, without talking about shrinking' {
        { Get-Plan 900 8 "gap:{disk-3}:$([int64]301GB)" } | Should -Throw '*free space is too small*'
    }
    It 'names the right drive when it can''t release enough' {
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMin = [int64]290GB } }
        { Get-Plan 25 8 "volume:{disk-3}:$([int64]1GB)" } | Should -Throw '*from E:*Make room*'
    }
}

Describe 'Test-System' {
    BeforeEach {
        Mock Test-Uefi { $true }
        Mock Get-CimInstance { [pscustomobject]@{ Architecture = 9 } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'GPT'; BusType = 'NVMe' } }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'ReFS'; HealthStatus = 'Healthy' } }
    }
    It 'goes on when C: is refused but another drive is fine' {
        Mock Get-DriveTargets { [pscustomobject]@{ Kind = 'volume'; Blocker = $null } }
        { Test-System } | Should -Not -Throw
    }
    It 'stops with C:''s reason when no drive will do' {
        Mock Get-DriveTargets { [pscustomobject]@{ Kind = 'disk'; Blocker = 'USB' } }
        { Test-System } | Should -Throw '*ReFS*'
    }
    It 'stops whatever the drives on Legacy BIOS' {
        Mock Test-Uefi { $false }
        Mock Get-DriveTargets { [pscustomobject]@{ Kind = 'volume'; Blocker = $null } }
        { Test-System } | Should -Throw '*Legacy BIOS*'
    }
}

Describe 'Get-UsblessPartitions on any disk' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { New-TestDisk -Number 0; New-TestDisk -Number 1; New-TestDisk -Number 2 -Bus 'USB' }
        Mock Get-Partition {
            $number = [int]@($DiskNumber)[0]
            [pscustomobject]@{ DiskNumber = $number; Offset = [int64]100GB * ($number + 1); Size = [int64]8GB; DriveLetter = 'H' }
        }
        Mock Read-State { }
        Mock Get-VolumeEntries { @() }
    }
    It 'does not take someone''s own drive for usbless''s because of its name' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLBOOT'; FileSystemType = 'FAT32' } }
        Mock Get-VolumeEntries { 'Photos', 'taxes.xlsx' }
        @(Get-UsblessPartitions).Count | Should -Be 0
    }
    It 'does not take a drive named for the installer with no boot loader on it' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLINSTALL'; FileSystemType = 'FAT32' } }
        Mock Get-VolumeEntries { 'Photos' }
        @(Get-UsblessPartitions).Count | Should -Be 0
    }
    It 'knows the installer by its boot loader with no state file' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLINSTALL'; FileSystemType = 'FAT32' } }
        Mock Get-VolumeEntries { 'casper', 'EFI', 'boot' }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Be @(0, 1)
    }
    It 'counts a drive with only what Windows puts on every drive as empty' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLROOT'; FileSystemType = 'exFAT' } }
        Mock Get-VolumeEntries { 'System Volume Information', '$RECYCLE.BIN' }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Be @(0, 1)
    }
    It 'does not take a drive it cannot look inside' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLBOOT'; FileSystemType = 'FAT32' } }
        Mock Get-VolumeEntries { throw 'denied' }
        @(Get-UsblessPartitions).Count | Should -Be 0
    }
    It 'trusts its own record of a partition, whatever is on it now' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLINSTALL'; FileSystemType = 'FAT32' } }
        Mock Get-VolumeEntries { 'half-copied' }
        Mock Read-State { [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'installer'; Offset = [int64]200GB; Size = [int64]8GB }) } }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Be @(1)
    }
    It 'finds usbless''s partitions on a second disk' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLINSTALL'; FileSystemType = 'FAT32'; DriveLetter = 'H' } }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Be @(0, 1)
    }
    It 'takes no notice of a USB drive, which could be from another PC' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLBOOT'; FileSystemType = 'FAT32' } }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Not -Contain 2
    }
    It 'needs the format to match off the Windows disk, so a drive that happens to have the name is safe' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLBOOT'; FileSystemType = 'NTFS' } }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Be @(0)
    }
    It 'expects exFAT for the Linux placeholder' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'USBLROOT'; FileSystemType = 'exFAT' } }
        @(Get-UsblessPartitions).Partition.DiskNumber | Should -Be @(0, 1)
    }
}

Describe 'Remembering what a drive really has' {
    BeforeAll {
        function New-Row([string]$Id, [int]$UsableGB, [bool]$Estimated) {
            $row = New-Object Usbless.DriveChoice
            $row.Id = $Id; $row.UsableGB = $UsableGB; $row.Estimated = $Estimated
            $row
        }
    }
    It 'replaces the estimate, so two stuck drives stop suggesting each other' {
        $drives = New-Object 'Collections.Generic.List[Usbless.DriveChoice]'
        $drives.Add((New-Row 'a' 300 $true))
        $drives.Add((New-Row 'b' 200 $true))
        [Usbless.DriveChoice]::Remember($drives, (New-Row 'a' 5 $false))
        $drives[0].UsableGB | Should -Be 5
        $drives[0].Estimated | Should -BeFalse
        $drives[1].UsableGB | Should -Be 200
    }
    It 'adds nothing for a drive no longer listed' {
        $drives = New-Object 'Collections.Generic.List[Usbless.DriveChoice]'
        $drives.Add((New-Row 'a' 300 $true))
        [Usbless.DriveChoice]::Remember($drives, (New-Row 'gone' 5 $false))
        $drives.Count | Should -Be 1
    }
}

Describe 'Get-LeftoverList' {
    BeforeEach {
        Mock Read-State { }
        Mock Get-Disk { New-TestDisk -Number 0 }
        Mock Get-RecordedPartitions { }
        Mock Get-FirmwareEntries { }
        Mock Get-BcdEntries { }
    }
    It 'says what would be deleted, with its size and drive' {
        Mock Get-UsblessPartitions {
            [pscustomobject]@{ Label = 'USBLINSTALL'; Partition = New-TestPartition -Letter 'H' -Disk 0 -Size ([int64]8GB) }
            [pscustomobject]@{ Label = 'USBLROOT'; Partition = New-TestPartition -Letter '' -Disk 0 -Size ([int64]59GB) }
        }
        $list = @(Get-LeftoverList)
        $list[0] | Should -BeLike '`*`*USBLINSTALL`*`*, 8 GB, drive H:, on *'
        $list[1] | Should -BeLike '`*`*USBLROOT`*`*, 59 GB, on *'
    }
    It 'lists what has no name yet, and a startup entry' {
        Mock Get-UsblessPartitions { }
        Mock Get-RecordedPartitions { New-TestPartition -Letter '' -Disk 0 -Size ([int64]8GB) }
        Mock Get-FirmwareEntries { 7 }
        $list = @(Get-LeftoverList)
        $list[0] | Should -BeLike '*unfinished partition*8 GB*'
        $list[1] | Should -BeLike '*startup menu*'
    }
    It 'has nothing to list on a clean PC' {
        Mock Get-UsblessPartitions { }
        @(Get-LeftoverList).Count | Should -Be 0
    }
}

Describe 'Get-StateDisk' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { New-TestDisk -Number 5 }
    }
    It 'follows a disk whose number changed since the install' {
        Get-StateDisk ([pscustomobject]@{ DiskNumber = 1; DiskGuid = '{disk-5}' }) | Should -Be 5
    }
    It 'uses the Windows disk for a setup from an older build' {
        Get-StateDisk ([pscustomobject]@{ DiskNumber = 1 }) | Should -Be 0
    }
    It 'says nothing when the disk has been unplugged' {
        Get-StateDisk ([pscustomobject]@{ DiskGuid = '{gone}' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-SpaceOwner' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { New-TestDisk -Number 1 }
    }
    It 'is C: for an older state file' {
        (Get-SpaceOwner ([pscustomobject]@{ DiskNumber = 0 }) @()).Windows | Should -BeTrue
    }
    It 'is the recorded volume, by offset' {
        Mock Get-Partition { New-TestPartition -Offset ([int64]1GB) }
        $owner = Get-SpaceOwner ([pscustomobject]@{ DiskGuid = '{disk-1}'; TargetKind = 'volume'; TargetOffset = [int64]1GB }) @()
        $owner.Windows | Should -BeFalse
        $owner.DiskNumber | Should -Be 1
        $owner.Offset | Should -Be ([int64]1GB)
    }
    It 'is nothing for free space' {
        Get-SpaceOwner ([pscustomobject]@{ DiskGuid = '{disk-1}'; TargetKind = 'gap'; TargetOffset = [int64]1GB }) @() | Should -BeNullOrEmpty
    }
    It 'is nothing when the disk has gone' {
        Get-SpaceOwner ([pscustomobject]@{ DiskGuid = '{gone}'; TargetKind = 'volume'; TargetOffset = [int64]1GB }) @() | Should -BeNullOrEmpty
    }
    Context 'with no state file' {
        BeforeEach {
            $found = @([pscustomobject]@{ Label = 'USBLINSTALL'; Partition = [pscustomobject]@{ DiskNumber = 1; Offset = [int64]300GB } })
        }
        It 'is C: when usbless''s partitions are on the Windows disk' {
            (Get-SpaceOwner $null @([pscustomobject]@{ Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]300GB } })).Windows | Should -BeTrue
        }
        It 'is the NTFS volume right before them on another disk' {
            Mock Get-Partition { New-TestPartition -Offset ([int64]1GB); New-TestPartition -Offset ([int64]100GB); New-TestPartition -Offset ([int64]300GB) }
            Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS' } }
            (Get-SpaceOwner $null $found).Offset | Should -Be ([int64]100GB)
        }
        It 'is nothing when what is before them is not a drive' {
            Mock Get-Partition { New-TestPartition -Letter '' -Offset ([int64]100GB) -Type $RecoveryType }
            Get-SpaceOwner $null $found | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-Cleanup on another drive' {
    BeforeEach {
        $script:resized = @()
        $script:removed = @()
        Mock Get-BcdEntries { }
        Mock Get-FirmwareEntries { }
        Mock Use-Esp { }
        Mock Get-RecordedPartitions { }
        Mock Add-LinuxDisk { }
        Mock Remove-PartitionAt { $script:removed += "$DiskNumber/$Offset" }
        Mock Get-UsblessPartitions { [pscustomobject]@{ Label = 'USBLINSTALL'; Partition = [pscustomobject]@{ DiskNumber = 4; Offset = [int64]300GB } } }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Size = [int64]100GB } }
        Mock Get-Disk { New-TestDisk -Number 4 }
        # Its number has shifted since the install: only the offset finds it.
        Mock Get-Partition { New-TestPartition -Letter 'E' -Disk 4 -Offset ([int64]1GB) -Size ([int64]200GB) | ForEach-Object { $_.PartitionNumber = 9; $_ } }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]300GB } }
        Mock Resize-Partition { $script:resized += "$DiskNumber/$PartitionNumber/$Size" }
        Mock Test-LinuxInstalled { $false }
    }
    It 'gives the space back to the volume it came from, found by offset' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; DiskGuid = '{disk-4}'; DiskNumber = 1; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $false } }
        Invoke-Cleanup
        $script:removed | Should -Be @("4/$([int64]300GB)")
        $script:resized | Should -Be @("4/9/$([int64]300GB)")
    }
    It 'leaves C: alone' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; DiskGuid = '{disk-4}'; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $false } }
        Invoke-Cleanup
        Should -Invoke Get-SupportedSize -ParameterFilter { $Partition.DiskNumber -eq 0 } -Times 0
    }
    It 'grows nothing when Linux only used free space' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false; DiskGuid = '{disk-4}'; TargetKind = 'gap'; TargetOffset = [int64]300GB; OnWindowsDisk = $false } }
        Invoke-Cleanup
        Should -Invoke Resize-Partition -Times 0
    }
    It 'still finishes when the disk has been unplugged' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; DiskGuid = '{gone}'; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $false } }
        Mock Get-UsblessPartitions { }
        { Invoke-Cleanup } | Should -Not -Throw
        Should -Invoke Resize-Partition -Times 0
    }
    It 'remembers the disk when Linux stays on it, so usbless can offer to remove it later' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; InstallerNextToWindows = $true; DiskGuid = '{disk-4}'; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $false; LoadersBefore = @() } }
        Mock Test-LinuxInstalled { $true }
        Invoke-Cleanup
        Should -Invoke Add-LinuxDisk -ParameterFilter { $Guid -eq '{disk-4}' } -Times 1
        Should -Invoke Resize-Partition -Times 1
    }
    It 'leaves a drive that never gave anything up at its size when Linux stays, so free space stays free' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false; InstallerNextToWindows = $true; DiskGuid = '{disk-4}'; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $false } }
        Invoke-Cleanup -InstallerOnly
        Should -Invoke Resize-Partition -Times 0
    }
    It 'does not remember a disk that was only used on the Windows disk' {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; InstallerNextToWindows = $true; DiskGuid = '{disk-4}'; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $true } }
        Invoke-Cleanup -InstallerOnly
        Should -Invoke Add-LinuxDisk -Times 0
    }
}

Describe 'Get-RecordedPartitions on another disk' {
    It 'looks on the disk the setup is on' {
        Mock Get-Disk { New-TestDisk -Number 2 }
        Mock Get-Partition { New-TestPartition -Disk 2 -Offset ([int64]500GB) -Size ([int64]8GB) } -ParameterFilter { $DiskNumber -contains 2 }
        Mock Read-PartitionHead { New-Object byte[] 16 }
        Mock Get-Volume { $null }
        $state = [pscustomobject]@{ DiskGuid = '{disk-2}'; Partitions = @([pscustomobject]@{ Role = 'installer'; Offset = [int64]500GB; Size = [int64]8GB }) }
        @(Get-RecordedPartitions $state @('installer')).Count | Should -Be 1
    }
}

Describe 'Test-LinuxInstalled on another disk' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { New-TestDisk -Number 2 }
        Mock Get-LinuxLoaders { }
    }
    It 'looks for Linux on the disk the setup is on, and for loaders there too' {
        Mock Get-Partition { } -ParameterFilter { $DiskNumber -contains 2 }
        Mock Get-LinuxPartitions { [pscustomobject]@{ Guid = '{new}' } }
        Test-LinuxInstalled ([pscustomobject]@{ DiskGuid = '{disk-2}'; LoadersBefore = @(); LinuxBefore = @() }) | Should -BeTrue
        Should -Invoke Get-LinuxLoaders -ParameterFilter { $Disks -contains 2 } -Times 1
    }
    It 'does not guess when the disk is unplugged' {
        Test-LinuxInstalled ([pscustomobject]@{ DiskGuid = '{gone}'; LoadersBefore = @(); LinuxBefore = @() }) | Should -BeFalse
    }
}

Describe 'Get-OtherSystem on another disk' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Find-OtherSystem { if ($Disk -eq 1) { [pscustomobject]@{ Name = 'Ubuntu'; OnWindowsDisk = $false } } }
        Mock Get-Disk { New-TestDisk -Number 0; New-TestDisk -Number 1 }
    }
    It 'leaves alone an ext4 disk that usbless did not put there' {
        Mock Get-LinuxDisks { }
        Get-OtherSystem | Should -BeNullOrEmpty
        Should -Invoke Find-OtherSystem -ParameterFilter { $Disk -eq 1 } -Times 0
    }
    It 'offers Linux that usbless put on another disk' {
        Mock Get-LinuxDisks { '{disk-1}' }
        (Get-OtherSystem).Name | Should -Be 'Ubuntu'
    }
}

Describe 'Remembering Linux on other disks' {
    BeforeEach { $LinuxDisksPath = Join-Path $TestDrive 'linux-disks.json' }
    AfterEach { Remove-Item $LinuxDisksPath -ErrorAction SilentlyContinue }
    It 'adds without repeating, and forgets' {
        Add-LinuxDisk '{a}'
        Add-LinuxDisk '{b}'
        Add-LinuxDisk '{a}'
        @(Get-LinuxDisks) | Should -Be @('{a}', '{b}')
        Set-LinuxDisks @()
        Test-Path $LinuxDisksPath | Should -BeFalse
    }
    It 'reads one disk back as a list' {
        Add-LinuxDisk '{a}'
        @(Get-LinuxDisks).Count | Should -Be 1
    }
}

Describe 'Test-AlongsideFindsLinux' {
    BeforeEach {
        Mock Get-Disk { New-TestDisk -Number 0; New-TestDisk -Number 1 }
        $plan = [pscustomobject]@{ DiskNumber = 0; FreeStart = [int64]500GB; LinuxGB = 60 }
    }
    It 'is true when usbless''s space is the largest free space anywhere' {
        Mock Get-DiskGaps { if ($Disk.Number -eq 0) { [pscustomobject]@{ Offset = [int64]500GB; Size = [int64]60GB } } }
        Mock Get-Partition { }
        Test-AlongsideFindsLinux $plan | Should -BeTrue
    }
    It 'is false when more is left over next to it' {
        Mock Get-DiskGaps { if ($Disk.Number -eq 0) { [pscustomobject]@{ Offset = [int64]500GB; Size = [int64]60GB }; [pscustomobject]@{ Offset = [int64]300GB; Size = [int64]190GB } } }
        Mock Get-Partition { }
        Test-AlongsideFindsLinux $plan | Should -BeFalse
    }
    It 'is false when another disk has more free' {
        Mock Get-DiskGaps { if ($Disk.Number -eq 1) { [pscustomobject]@{ Offset = [int64]1MB; Size = [int64]900GB } } }
        Mock Get-Partition { }
        Test-AlongsideFindsLinux $plan | Should -BeFalse
    }
}

Describe 'Get-Steps by where Linux goes' {
    BeforeAll {
        $second = [pscustomobject]@{ OnWindowsDisk = $false; DiskName = 'WD Blue'; DiskGB = 1000 }
        function Get-Text($Id, $Place) {
            $result = Get-Steps (Get-Catalog | Where-Object Id -eq $Id) 60 $Place
            ($result.Steps + $result.Notes) -join ' '
        }
    }
    It 'stays as it was without a place, and for C:' {
        Get-Text 'ubuntu' $null | Should -BeLike '*alongside Windows*It uses the 60 GB*'
        Get-Text 'ubuntu' ([pscustomobject]@{ OnWindowsDisk = $true; AlongsideOk = $true }) | Should -BeLike '*alongside Windows*'
    }
    It 'adds nothing about Fast Boot on the Windows disk' {
        Get-Text 'ubuntu' $null | Should -Not -BeLike '*Fast Boot*'
    }
    It 'goes to the manual screen when more is free elsewhere' {
        $text = Get-Text 'ubuntu' ([pscustomobject]@{ OnWindowsDisk = $true; AlongsideOk = $false })
        $text | Should -Not -Match 'Choose \*\*Install Ubuntu alongside'
        $text | Should -BeLike '*Manual installation*60 GB*'
    }
    It 'on a second disk, goes to manual, names the disk and asks for the boot loader first' {
        $text = Get-Text 'ubuntu' $second
        $text | Should -Not -BeLike '*alongside*'
        $text | Should -BeLike '*Manual installation*Device for boot loader installation*WD Blue (1000 GB)*Select the 60 GB*WD Blue (1000 GB)*'
        $text | Should -BeLike '*Erase disk*'
        $text | Should -BeLike '*Fast Boot*'
    }
    It 'tells Mint''s users to leave the boot loader list, since it always uses the first EFI partition' {
        $mint = Get-Catalog | Where-Object Id -eq 'mint-mate'
        $mint.Steps = $null; $mint.Strategy = 'freespace'
        $result = Get-Steps $mint 60 $second
        $text = ($result.Steps + $result.Notes) -join ' '
        $text | Should -BeLike '*Something else*Leave **Device for boot loader installation** as it is*'
        $text | Should -Not -Match 'choose \*\*WD Blue'
    }
    It 'keeps Lubuntu''s step for the existing EFI partition' {
        $text = Get-Text 'lubuntu' $second
        $text | Should -BeLike '*EFI System Partition*'
        $text | Should -Not -BeLike '*Device for boot loader*'
    }
    It 'names usbless''s partitions for elementary and Pop!_OS on a second disk, which start from there' {
        $text = Get-Text 'elementary' $second
        $text | Should -BeLike "*$RootLabel*$BootLabel*"
        $text | Should -BeLike '*Fast Boot*'
    }
}

Describe 'Make room on another drive' {
    BeforeAll { $RoomPath = Join-Path $TestDrive 'make-room.json' }
    BeforeEach {
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        Mock Test-HibernationOn { $true }
        Mock Test-EnoughMemoryWithoutPaging { $true }
        Mock Get-PagingSettings { @("$env:SystemDrive\pagefile.sys 0 0") }
        Mock Set-Hibernation { }
        Mock Clear-ChangeJournal { }
        Mock New-ChangeJournal { }
        Mock Set-PagingOff { }
        Mock Restore-Paging { }
        Mock Register-RunAfterRestart { }
        Mock Unregister-RunAfterRestart { }
        Mock Unregister-ResumeTask { }
        Mock Invoke-Shutdown { }
        Mock Invoke-Defrag { }
        Mock Get-LastBoot { [datetime]'2030-01-01' }
    }
    It 'needs no restart and leaves hibernation alone' {
        Start-MakeRoom 'Y' | Should -Be 'done'
        Should -Invoke Set-Hibernation -Times 0
        Should -Invoke Set-PagingOff -Times 0
        Should -Invoke Invoke-Shutdown -Times 0
        Should -Invoke Clear-ChangeJournal -ParameterFilter { $Drive -eq 'Y:' } -Times 1
        Should -Invoke Invoke-Defrag -ParameterFilter { $Drive -eq 'Y:' } -Times 1
    }
    It 'restarts only when that drive has a paging file' {
        Mock Get-PagingSettings { @('Y:\pagefile.sys 0 0') }
        Start-MakeRoom 'Y' | Should -Be 'restarting'
        Should -Invoke Set-PagingOff -ParameterFilter { $Drive -eq 'Y:' } -Times 1
        Should -Invoke Set-Hibernation -Times 0
        Should -Invoke Invoke-Shutdown -Times 1
    }
    It 'moves files on the same drive after the restart' {
        Mock Get-PagingSettings { @('Y:\pagefile.sys 0 0') }
        Start-MakeRoom 'Y'
        Complete-MakeRoom
        Should -Invoke Invoke-Defrag -ParameterFilter { $Drive -eq 'Y:' } -Times 1
    }
    It 'puts the change journal back on that drive, and not hibernation' {
        Start-MakeRoom 'Y'
        Restore-RoomSettings
        Should -Invoke New-ChangeJournal -ParameterFilter { $Drive -eq 'Y:' } -Times 1
        Should -Invoke Set-Hibernation -Times 0
    }
    It 'only takes the paging file off that drive, and not one Windows places itself' {
        Get-PagingWithoutSystemDrive @('Y:\pagefile.sys 0 0', "$env:SystemDrive\pagefile.sys 0 0", '?:\pagefile.sys') 'Y' |
            Should -Be @("$env:SystemDrive\pagefile.sys 0 0", '?:\pagefile.sys')
    }
    It 'behaves as it always has for C:' {
        Start-MakeRoom '' | Should -Be 'restarting'
        Should -Invoke Set-Hibernation -ParameterFilter { -not $On } -Times 1
        Should -Invoke Set-PagingOff -Times 1
        Should -Invoke Invoke-Shutdown -Times 1
    }
    It 'reads a file from an older build as C:' {
        Set-Content -LiteralPath $RoomPath -Value '{"Phase":"ready","Saved":"2030-01-01T00:00:00","Hibernation":false,"PagingOff":false}'
        Restore-RoomSettings
        Should -Invoke New-ChangeJournal -Times 1
        Get-RoomDrive $null | Should -Be $env:SystemDrive
    }
    It 'says no restart in its steps when none is needed' {
        $plan = Get-MakeRoomSteps 'Y'
        $plan.Restart | Should -BeFalse
        ($plan.Steps -join ' ') | Should -Not -BeLike '*hibernation*'
        ($plan.Notes -join ' ') | Should -BeLike "*doesn't restart*"
    }
    It 'keeps C:''s steps as they were' {
        $plan = Get-MakeRoomSteps ''
        $plan.Restart | Should -BeTrue
        ($plan.Steps -join ' ') | Should -BeLike '*hibernation*paging file*Restarts*'
    }
}

Describe 'Get-DownloadFolder' {
    BeforeEach { Mock New-Item { } }
    It 'uses the Downloads folder when nothing is named' {
        Get-DownloadFolder | Should -Not -BeLike 'Y:*'
    }
    It 'uses a usbless folder on another drive' {
        Get-DownloadFolder 'Y' | Should -Be 'Y:\usbless'
    }
    It 'keeps the Downloads folder when it is already on that drive' {
        $usual = Get-DownloadFolder
        Get-DownloadFolder $usual.Substring(0, 1) | Should -Be $usual
    }
}

Describe 'Get-DownloadDrives' {
    BeforeEach {
        Mock Get-DownloadFolder { 'E:\Downloads' }
        Mock Get-Volume {
            [pscustomobject]@{ DriveLetter = 'E'; DriveType = 'Fixed'; FileSystemType = 'NTFS'; SizeRemaining = [int64]400GB }
            [pscustomobject]@{ DriveLetter = 'F'; DriveType = 'Removable'; FileSystemType = 'exFAT'; SizeRemaining = [int64]50GB }
            [pscustomobject]@{ DriveLetter = 'G'; DriveType = 'Fixed'; FileSystemType = 'FAT32'; SizeRemaining = [int64]50GB }
            [pscustomobject]@{ DriveLetter = 'H'; DriveType = 'CD-ROM'; FileSystemType = 'UDF'; SizeRemaining = [int64]0 }
            [pscustomobject]@{ DriveLetter = 'I'; DriveType = 'Fixed'; FileSystemType = 'Unknown'; SizeRemaining = [int64]0 }
            [pscustomobject]@{ DriveLetter = $null; DriveType = 'Fixed'; FileSystemType = 'NTFS'; SizeRemaining = [int64]5GB }
        }
    }
    It 'lists only drives that can hold a big file, USB included, and marks the usual one' {
        $drives = @(Get-DownloadDrives)
        ($drives.Letter -join ',') | Should -Be 'E,F'
        $drives[0].IsDefault | Should -BeTrue
        $drives[1].IsDefault | Should -BeFalse
    }
}

Describe 'Get-Warnings for the chosen drive' {
    BeforeEach {
        Mock Get-OtherInstallers { }
        Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = [int64]16GB } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ BusType = 'NVMe'; Number = 0 } }
        Mock Test-RestartPending { $false }
        Mock Test-BitLockerOn { $false }
        Mock Get-PartitionSignature { $null }
    }
    It 'mentions Fast Boot for a second disk' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'gap'; Disk = [pscustomobject]@{ Number = 1 } } }
        Get-Warnings 'gap:x:1' | Should -BeLike '*Fast Boot*'
    }
    It 'stays quiet for another drive on the Windows disk' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'volume'; Disk = [pscustomobject]@{ Number = 0 }; Partition = (New-TestPartition -Disk 0) } }
        @(Get-Warnings 'volume:x:1').Count | Should -Be 0
    }
    It 'warns about a BitLocker drive it will shrink' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'volume'; Disk = [pscustomobject]@{ Number = 0 }; Partition = (New-TestPartition -Disk 0) } }
        Mock Get-PartitionSignature { 'bitlocker' }
        Get-Warnings 'volume:x:1' | Should -BeLike '*Drive D: is encrypted*'
    }
}

Describe 'Assert-DriveUsable' {
    It 'stops an install on a drive that has since been refused' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'gap'; IsWindows = $false; Disk = (New-TestDisk -Bus 'USB') } }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        { Assert-DriveUsable 'gap:x:1' } | Should -Throw '*USB*'
    }
    It 'checks C: with C:''s own rules' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'volume'; IsWindows = $true; Partition = (New-TestPartition -Letter 'C' -Disk 0) } }
        Mock Get-Disk { New-TestDisk -Number 0 -Bus 'USB' }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy' } }
        { Assert-DriveUsable '' } | Should -Not -Throw
    }
}
