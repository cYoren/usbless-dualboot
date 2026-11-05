# The one-time start is still set, so the firmware never acted on it.
function Test-BootNextIgnored($State) {
    if ($null -eq $State.BootNumber) { return $false }
    $next = try { [Usbless.Firmware]::BootNext() } catch { $null }
    $null -ne $next -and $next -eq [int]$State.BootNumber
}

# The firmware took usbless's entry out of its list after the restart, which is what Boot Order
# Lock does on some Lenovo PCs. Telling those two apart from Secure Boot avoids a needless change.
function Test-EntryDropped($State) {
    if ($null -eq $State.BootNumber) { return $false }
    $number = [int]$State.BootNumber
    try { $number -notin @(Get-FirmwareEntries) -or $number -notin @([Usbless.Firmware]::BootOrderNumbers()) } catch { $false }
}

# When the PC came back to Windows instead of starting the installer.
function Get-ReturnedHelp {
    $state = Read-State
    $entry = "$($state.Distro) installer $EntryMarker"
    $key = Get-BootMenuKey
    if (Test-EntryDropped $state) {
        $steps = @(
            "This PC's firmware removed usbless's startup entry, so it never tried the installer."
            'If its BIOS has a **Boot Order Lock** setting, turn it off. **Open BIOS** takes you there.'
            'Click **Try again**, which adds the entry back.'
        )
        $notes = @("If it still comes back to Windows, restart and keep tapping **$key** as the PC powers on, then choose **$entry**.")
    } elseif (Test-BootNextIgnored $state) {
        $steps = @(
            "This PC ignored usbless's request to start the installer. Restart and keep tapping **$key** as the PC powers on, which opens its boot menu."
            "Choose **$entry**."
        )
        $notes = @("If it isn't listed, this PC's firmware removed it. Click **Try again** and usbless adds it back.")
    } elseif (Test-SecureBoot) {
        $steps = @(
            "Restart and keep tapping **$key** as the PC powers on, then choose **$entry**."
            'If you see a security error or Windows again, Secure Boot may have stopped it. Click **Open BIOS**.'
            'Find **Secure Boot**, usually under Security or Boot, set it to **Disabled**, then save and exit.'
        )
        $notes = @()
    } else {
        $steps = @(
            "Restart and keep tapping **$key** as the PC powers on, which opens its boot menu."
            "Choose **$entry**."
        )
        $notes = @("If it isn't listed, this PC's firmware removed it. Click **Try again** and usbless adds it back.")
    }
    [pscustomobject]@{ Steps = $steps; Notes = $notes }
}

# A catalog entry's own Steps are written for the disk Windows is on: some say to use "the existing EFI
# partition" on the drive with free space, which a second disk hasn't got. A system that hasn't been seen
# installing on a second disk has no SecondDisk steps, so it's refused rather than guessed at. Replacing
# Windows isn't affected: its installer always goes on Windows' disk.
function Assert-SystemFitsDrive($Distro, [string]$Target) {
    if ($Distro.Refused) { throw $Distro.Refused }
    if (-not $Distro.Steps -or $Distro.SecondDisk -or -not $Target) { return }
    if ((Resolve-Target $Target).Partition.DiskNumber -eq (Get-WindowsPartition).DiskNumber) { return }
    throw "usbless hasn't got $($Distro.Name) to finish on a second disk yet. Choose a drive on the disk Windows is on, or another system."
}

# What the Linux installer adds to Windows' EFI partition. On a second disk, some make their own instead.
function Get-EspLinuxMB($Distro, [bool]$OnWindowsDisk) {
    if (-not $OnWindowsDisk -and $Distro.SecondDisk -and $Distro.SecondDisk.ContainsKey('EspLinuxMB')) { return [int]$Distro.SecondDisk.EspLinuxMB }
    [int]$Distro.EspLinuxMB
}

# The most an installer's refusal can cost is a restart, but it's cheaper here, before the download.
function Assert-SystemFitsSpace($Distro, [int]$LinuxGB) {
    if ($Distro.MinGB -and $LinuxGB -lt $Distro.MinGB) { throw "$($Distro.Name)'s installer needs at least $($Distro.MinGB) GB. Set the Linux size to that or more and click Install again." }
}

# BitLocker's mark, at the start of a partition, whether it's locked, unlocked or paused. It stays until the drive has finished decrypting.
function Test-BitLockerHead([byte[]]$Head) {
    $Head.Length -ge 11 -and [Text.Encoding]::ASCII.GetString($Head, 3, 8) -ceq '-FVE-FS-'
}

function Read-PartitionHead($Partition) { [Usbless.DiskProbe]::ReadHead($Partition.DiskNumber, [int64]$Partition.Offset) }

# Omarchy's installer reads every partition on its disk for that mark, and stops if it finds one. Pausing BitLocker, which
# usbless does for everything else, doesn't remove it. So this looks the same way, while nothing has changed. Turning it off is
# the owner's decision, and usbless doesn't make it. Not being able to look counts as a no: the installer would look too.
function Assert-NoBitLocker($Distro, [string]$Target) {
    if (-not $Distro.NoBitLocker) { return }
    $disk = if ($Target) { (Resolve-Target $Target).Partition.DiskNumber } else { (Get-WindowsPartition).DiskNumber }
    foreach ($partition in @(Get-Partition -DiskNumber $disk)) {
        $head = try { Read-PartitionHead $partition } catch { throw "usbless couldn't check this disk for BitLocker, which $($Distro.Name)'s installer refuses: $($_.Exception.Message)" }
        if (Test-BitLockerHead $head) {
            $letter = Get-LetterOf $partition
            $name = if ($letter) { "Drive $letter`:" } else { 'A drive on this disk' }
            throw "$name is encrypted with BitLocker, and $($Distro.Name)'s installer won't use a disk with BitLocker on it. Pausing it isn't enough. To install $($Distro.Name), turn off BitLocker or Device encryption in Windows Settings, wait until the drive has finished decrypting, then open usbless again. usbless won't do this for you."
        }
    }
}

# What to click in the Linux installer. The app shows Steps as a numbered list
# and Notes underneath; text between ** is shown in a heavier weight. $Place is the
# saved state, which says where Linux is going; without it, that's next to C:.
function Get-Steps($Distro, [int]$LinuxGB, $Place) {
    if ($Place.FullDisk) { return Get-FullDiskSteps $Distro $Place }
    $otherDisk = $Place.OnWindowsDisk -eq $false
    $own = if ($otherDisk -and $Distro.SecondDisk) { $Distro.SecondDisk } else { $Distro }
    if ($Distro.Steps) {
        $steps = @($own.Steps | ForEach-Object { $_ -replace '\{GB\}', $LinuxGB -replace '\{ROOTMB\}', [int64][math]::Floor(([int64]$LinuxGB - 1) * 1GB / 1000000) -replace '\{DISK\}', "$($Place.DiskName) ($($Place.DiskGB) GB)" })
    } elseif ($Distro.Strategy -eq 'prepared') {
        $steps = @(
            "Pick your language and keyboard, then choose **$($Distro.Mode)**."
            "Click the $($LinuxGB - 1) GB partition named **$RootLabel**. Use it as Root (/) and format it as ext4."
            "Click the 1 GB partition named **$BootLabel**. Use it as Boot (/boot/efi) and format it as FAT32."
            'Leave everything else alone and click **Install**.'
        )
    } else {
        $manual = "choose **$($Distro.Manual)**, select the $LinuxGB GB of free space, click **+** and create an ext4 partition mounted at **/**."
        $steps = @('Pick your language and keyboard, then start the installer.')
        if ($otherDisk) {
            $steps += Get-OtherDiskSteps $Distro $LinuxGB "$($Place.DiskName) ($($Place.DiskGB) GB)"
        } elseif ($Distro.Alongside -and $Place.AlongsideOk -ne $false) {
            $steps += "Choose **$($Distro.Alongside)**. It uses the $LinuxGB GB usbless set aside."
            $steps += "If that option is missing, $manual"
        } else {
            $steps += "When asked how to install, $manual"
        }
        if ($Distro.ManualExtra) { $steps += $Distro.ManualExtra }
        $steps += "Don't choose **Erase disk**. The installer is running from this drive."
    }
    $notes = @('If the PC starts Windows again or shows a security error, turn off Secure Boot in the BIOS, then open usbless and restart again.')
    if ($own.Notes) { $notes += @($own.Notes | ForEach-Object { $_ -replace '\{DISK\}', "$($Place.DiskName) ($($Place.DiskGB) GB)" }) }
    if ($otherDisk) { $notes += 'If it stops at a **grub>** prompt, turn off **Fast Boot** in the BIOS, because it can hide a second drive. Hold the power button to get back to Windows.' }
    [pscustomobject]@{ Steps = $steps; Notes = $notes }
}

# The easy "alongside" option takes the largest free space on any disk and is often missing on
# a second one, so these go straight to the manual screen and name the disk. Ubuntu's asks where
# its boot loader goes, and only makes a partition for it in free space that's still there. So
# that comes first. Linux Mint's has no real choice: it always uses the first EFI partition.
function Get-OtherDiskSteps($Distro, [int]$LinuxGB, [string]$Disk) {
    $bootLoader = if ($Distro.Manual -eq 'Something else') {
        " Leave **Device for boot loader installation** as it is: this installer puts its startup files on the first EFI partition it finds, usually Windows'."
    } elseif (-not $Distro.ManualExtra) {
        " If there's a **Device for boot loader installation** list, choose **$Disk** there first."
    }
    "When asked how to install, choose **$($Distro.Manual)**.$bootLoader"
    "Select the $LinuxGB GB of free space on **$Disk**, click **+** and create an ext4 partition mounted at **/**."
}
