# --- Replacing Windows --------------------------------------------------------
# usbless never erases anything here. It makes the same installer partition as ever, on the disk
# Windows is on, and asks the live system to copy itself to memory so that it lets go of that
# disk. The Linux installer does the erasing, if and when someone chooses that there. Until
# then Windows is untouched, and Undo works as it does for any other install.
# Only systems with FullDisk in their catalog entry are offered this: see Get-Catalog.

$FullDiskMemoryRoom = 4GB    # what the live system and its installer need, on top of the copy
$MsrType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

function Get-MemoryBytes { [int64](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }

# Windows reports slightly less than what's fitted, so 16 GB shows as 15.8. Rounded up, it reads as people know it.
function Get-MemoryGB { [int][math]::Ceiling((Get-MemoryBytes) / 1GB) }

# The copy has to fit in memory with room left. Ubuntu's ISO, 6 GB, in a virtual PC with 7 GB of memory
# copied itself and then didn't get to a login in seven minutes. So it's refused here, while that's cheap.
function Get-FullDiskMemoryBlocker($Distro, [int64]$IsoBytes) {
    $needed = $IsoBytes + $FullDiskMemoryRoom
    $memory = Get-MemoryBytes
    if ($memory -ge $needed) { return }
    "Replacing Windows needs at least $([int][math]::Ceiling($needed / 1GB)) GB of memory, because $($Distro.Name) has to copy itself there first and still have room to run. This PC has $(Get-MemoryGB) GB. You can still install it next to Windows."
}

# Why Windows can't be replaced with this system on this PC, in plain words, or nothing.
function Get-FullDiskBlocker($Distro) {
    if (-not $Distro.FullDisk) { return "usbless hasn't shown that replacing Windows works with $($Distro.Name), so it doesn't offer it. You can still install it next to Windows." }
    if ($Distro.SecureBootOff -and (Test-SecureBoot)) { return "$($Distro.Name) doesn't start with Secure Boot on. Turn off Secure Boot in the BIOS and open usbless again." }
    $windows = Get-WindowsPartition
    $disk = Get-Disk -Number $windows.DiskNumber
    $reason = Get-DriveBlocker $disk $windows -Windows
    if ($reason) { return $reason }
    if ($disk.BusType -eq 'RAID') { return "This PC's drive is in RAID or Intel RST mode, which most Linux installers can't see. Change that in the BIOS first, which needs care while Windows is still on it." }
    $leastGB = [math]::Max([int]$MinLinuxGB, [int]$Distro.MinGB)
    if ([int64]$disk.Size -lt [int64]$leastGB * 1GB) { return "$(Get-DiskLabel $disk) is too small for $($Distro.Name). It needs at least $leastGB GB." }
    # Erasing this disk then wouldn't take the startup files with it, and usbless hasn't tried that.
    $esp = try { Get-WindowsEsp } catch { $null }
    if (-not $esp -or $esp.DiskNumber -ne $windows.DiskNumber) { return 'Windows starts from a different disk from the one it is on, so usbless can''t tell what erasing it would leave behind. You can still install Linux next to Windows.' }
    # The name and size are all usbless can give the Linux installer's list, which then can't tell these apart.
    $sameGB = Get-DiskGB $disk
    $twin = @(Get-Disk | Where-Object { $_.Number -ne $disk.Number -and (Get-DiskLabel $_) -eq (Get-DiskLabel $disk) -and (Get-DiskGB $_) -eq $sameGB })
    if ($twin.Count) { return "This PC has more than one disk called $(Get-DiskLabel $disk) ($sameGB GB). The Linux installer's list wouldn't show which of them holds Windows, and the wrong one could be erased. Disconnect the other one first, or install Linux next to Windows." }
    Get-FullDiskMemoryBlocker $Distro ([int64]$Distro.FullDisk.IsoGB * 1GB)
}


# Whether BitLocker is on for a drive. Win32_EncryptableVolume only answers an administrator, which usbless is.
function Test-DriveEncrypted([string]$Letter) {
    try {
        $volume = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$Letter`:'" -ErrorAction SilentlyContinue
        [bool]($volume -and $volume.ProtectionStatus -eq 1)
    } catch { $false }
}

# What people would call each thing on the disk that would go. The EFI, reserved and recovery
# partitions aren't listed: they're Windows' own, and it's said plainly that Windows goes.
function Get-VolumesOnDisk([int]$DiskNumber) {
    $windows = Get-WindowsPartition
    foreach ($partition in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Sort-Object { [int64]$_.Offset })) {
        if ($partition.GptType -in @($EspType, $MsrType, $RecoveryType)) { continue }
        $letter = Get-LetterOf $partition
        $volume = try { $partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
        $gb = [int][math]::Round([int64]$partition.Size / 1GB)
        $isWindows = $DiskNumber -eq $windows.DiskNumber -and [int64]$partition.Offset -eq [int64]$windows.Offset
        $name = if ($isWindows) { 'Windows' } else { [string]$volume.FileSystemLabel }
        $encrypted = (Get-PartitionSignature $partition) -eq 'bitlocker'
        if ($letter) { $encrypted = $encrypted -or (Test-DriveEncrypted $letter) }
        $what = if ($letter) { "drive $letter`:" } elseif ($encrypted) { 'a locked BitLocker drive' } elseif (Test-LinuxSignature $partition) { 'a Linux partition' } else { 'a partition with no letter' }
        [pscustomobject]@{ What = $what; Name = $name; SizeGB = $gb; Encrypted = $encrypted }
    }
}

function Format-VolumeList($Volumes) {
    @($Volumes | ForEach-Object { if ($_.Name) { "**$($_.What)** ($($_.Name), $($_.SizeGB) GB)" } else { "**$($_.What)** ($($_.SizeGB) GB)" } }) -join ', '
}

# Folders on an EFI partition holding a Linux boot loader, and not usbless's. Makers' own folders, such as
# \EFI\Dell, have no such file, and aren't systems.
function Get-EspLoaderFolders([string]$Root) {
    $keep = @('Microsoft', 'Boot') + @($EspFolders | ForEach-Object { Split-Path $_ -Leaf })
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $Root 'EFI') -Directory -Force | Where-Object { $_.Name -notin $keep })) {
        if (@(Get-ChildItem -LiteralPath $folder.FullName -File -Force | Where-Object { $_.Name -match $LinuxLoaderPattern }).Count) { $folder.Name }
    }
}

# Other copies of Windows in the startup menu kept on this partition, as bcdedit lists them. Its field
# names are translated and its values aren't. Windows' recovery system runs from a ramdisk, and isn't one.
function Get-OtherWindowsLoaders {
    foreach ($block in ((Invoke-Bcdedit /enum osloader) -split '(?:\r?\n){2,}')) {
        if ($block -notmatch '(?i)\\winload\.efi' -or $block -match '\{current\}' -or $block -match '(?i)ramdisk=' -or $block -match $EntryPattern) { continue }
        $found = [regex]::Match($block, '(?i)partition=([A-Z]:)')
        if ($found.Success) { "Windows on drive $($found.Groups[1].Value)" } else { 'another copy of Windows' }
    }
}

# What else starts from Windows' EFI partition, which goes with this disk. Linux Mint's installer puts
# its files there whichever disk Linux is on, and a second Windows can share it. Throws if it can't tell.
function Get-SystemsOnWindowsEsp {
    $esp = Get-WindowsEsp
    $entries = @(Get-BootEntries | Where-Object { $_.PartitionGuid -eq $esp.Guid -and $_.Path -and $_.Description -notmatch $EntryPattern })
    $folders = @(Use-Esp { param($root) Get-EspLoaderFolders $root })
    $linux = foreach ($folder in $folders) {
        $entry = $entries | Where-Object { ($_.Path -split '\\')[2] -eq $folder } | Select-Object -First 1
        if ($entry.Description) { $entry.Description } else { $folder }
    }
    @(@($linux) + @(Get-OtherWindowsLoaders) | Where-Object { $_ } | Select-Object -Unique)
}

# Everything the warning has to say, read fresh, and why not if it can't be done. $Target is the
# drive chosen so far: the installer goes there if it's on Windows' disk, otherwise next to C:.
function Get-FullDiskPlan([string]$DistroId, [string]$Target) {
    $distro = Get-Distro $DistroId ''
    $blocker = Get-FullDiskBlocker $distro
    $plan = [pscustomobject]@{ Blocker = $blocker; Target = $null; DiskName = ''; DiskGB = 0; Points = @(); StopsStarting = @() }
    if ($blocker) { return $plan }
    # Better to refuse than to promise other systems are safe without having looked.
    try { $plan.StopsStarting = @(Get-SystemsOnWindowsEsp) } catch {
        Write-Log "Could not read what starts from the EFI partition: $($_.Exception.Message)"
        $plan.Blocker = "usbless couldn't read what starts from this disk's EFI partition, so it can't say what erasing the disk would stop. You can still install Linux next to Windows."
        return $plan
    }

    $windows = Get-WindowsPartition
    $disk = Get-Disk -Number $windows.DiskNumber
    $place = $null
    if ($Target) { $place = try { Resolve-Target $Target } catch { $null } }
    if (-not $place -or $place.IsWindows -or $place.Partition.DiskNumber -ne $windows.DiskNumber) { $Target = '' }
    $plan.Target = Get-DriveSpace $Target
    $plan.DiskName = Get-DiskLabel $disk
    $plan.DiskGB = Get-DiskGB $disk

    $others = @(Get-Disk | Where-Object { $_.Number -ne $disk.Number } | ForEach-Object { "**$(Get-DiskLabel $_)** ($(Get-DiskGB $_) GB)" })
    $stops = @($plan.StopsStarting | ForEach-Object { "**$_**" }) -join ', '
    $plan.Points = @(
        "**These go too:** $(Format-VolumeList @(Get-VolumesOnDisk $disk.Number))."
        $(if ($stops) { "**These stop starting:** $stops. They start from the EFI partition on this disk, which goes too. Whatever of theirs is on another disk stays, but won't start until it's repaired." })
        "**Back up what you want to keep first.** A BitLocker recovery key won't help afterwards: an erased drive has nothing left to unlock."
        $(if ($others.Count) { "**$(if ($stops) { 'What''s stored on other disks stays' } else { 'Other disks stay as they are' }):** $($others -join ', ')." } else { "This PC has no other disk, so nothing else is left to keep a copy on." })
        "**Nothing is erased yet.** usbless only makes the installer. The Linux installer erases the disk when you choose that there, after the PC restarts. Undo works until then."
    ) | Where-Object { $_ }
    $plan
}

# Checked again when the install starts: the window could have been open for a while.
function Assert-FullDisk($Distro) {
    $reason = Get-FullDiskBlocker $Distro
    if ($reason) { throw $reason }
}

# Once the ISO is there, its real size and its real boot menu count. Nothing on the disk has changed yet.
function Assert-FullDiskIso($Distro, $Iso) {
    $reason = Get-FullDiskMemoryBlocker $Distro $Iso.Bytes
    if ($reason) { throw $reason }
    if (-not (Test-BootConfigKnown $Distro "$($Iso.Letter):\" -FullDisk)) {
        throw "This version of $($Distro.Name) starts in a way usbless doesn't know yet, so it couldn't let go of the disk. Nothing has been changed. You can still install it next to Windows."
    }
}

# What to click once the installer is running. The system's own words, naming the disk.
function Get-FullDiskSteps($Distro, $Place) {
    $disk = "$($Place.DiskName) ($($Place.DiskGB) GB)"
    $steps = if ($Distro.FullDisk.Steps) { @($Distro.FullDisk.Steps) } else { @(
        'Pick your language and keyboard, then start the installer.'
        'When asked how to install, choose to erase the disk, and pick **{DISK}**.'
        'Check it names only that disk, then confirm.') }
    [pscustomobject]@{
        Steps = @($steps | ForEach-Object { $_ -replace '\{DISK\}', $disk })
        Notes = @(
            "If **$disk** isn't offered or the installer says it's in use, don't force it. Turn the PC off and on to get back to Windows, which is still there."
            'If the PC starts Windows again or shows a security error, turn off Secure Boot in the BIOS, then open usbless and restart again.')
        FullDisk = $true
    }
}
