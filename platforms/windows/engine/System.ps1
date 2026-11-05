# What stops usbless on this PC whichever drive is chosen.
function Get-PcBlockers {
    if (-not (Test-Uefi)) {
        'This PC starts in the old "Legacy BIOS" mode. usbless only works on UEFI PCs.'
        return
    }
    if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -eq 12) {
        'This PC has an ARM processor. The systems usbless installs are built for Intel and AMD processors.'
        return
    }
}

# What makes usbless refuse to use C:, or to run at all, with the reason in plain words.
function Get-Blockers {
    $pc = @(Get-PcBlockers)
    if ($pc.Count) { return $pc }
    $c = Get-WindowsPartition
    Get-DriveBlocker (Get-Disk -Number $c.DiskNumber) $c -Windows
}

function Test-Uefi { [Usbless.Firmware]::IsUefi() }

# A problem with C: only stops usbless when there's no other drive to use.
function Test-System {
    $blockers = @(Get-Blockers)
    if (-not $blockers.Count) { return }
    if (@(Get-PcBlockers).Count) { throw $blockers[0] }
    if (-not @(Get-DriveTargets | Where-Object { -not $_.Blocker -and $_.Kind -ne 'disk' }).Count) { throw $blockers[0] }
}

# Things usbless can go ahead with, but that are worth checking first. ** marks emphasis.
function Get-Warnings([string]$Target) {
    Get-RoomGaveUpWarning
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($battery -and $battery.BatteryStatus -eq 1) {
        "**Plug in the charger.** This PC is on battery ($($battery.EstimatedChargeRemaining)%), and losing power while the disk is changing could stop Windows starting."
    }
    if ((Get-Disk -Number (Get-WindowsPartition).DiskNumber).BusType -eq 'RAID') {
        '**The drive is in RAID or Intel RST mode.** Most Linux installers can''t see a drive set up this way. Windows also needs care to switch to AHCI in the BIOS, so look up the steps for this PC before continuing.'
    }
    foreach ($other in @(Get-OtherInstallers)) {
        if ($other.Usb) { "**Unplug $($other.Name).** It holds a Linux installer, and the PC could start that one instead of the one usbless makes." }
        else { "**$($other.Name) also holds a Linux installer.** The PC could start that one instead. Delete it in Disk Management if you don't need it." }
    }
    if (Test-RestartPending) {
        '**Windows is waiting to restart for an update.** Restart and let it finish first. Otherwise it could be interrupted when the PC starts the installer.'
    }
    if (Test-BitLockerOn) {
        '**Drive C: is encrypted with BitLocker.** usbless pauses it for three restarts. Make sure you have the recovery key first, at account.microsoft.com/devices/recoverykey.'
    }
    if ($Target) {
        $place = Resolve-Target $Target
        if ($place.Disk.Number -ne (Get-WindowsPartition).DiskNumber) {
            '**Linux goes on a second drive.** If the PC stops at a **grub>** prompt when it restarts, turn off **Fast Boot** in the BIOS, because it can hide a second drive. Hold the power button to get back to Windows.'
        }
        if ($place.Kind -eq 'volume' -and (Get-PartitionSignature $place.Partition) -eq 'bitlocker') {
            "**Drive $(Get-LetterOf $place.Partition): is encrypted with BitLocker.** usbless can shrink it while it's unlocked, and Linux won't be able to read it. Make sure you have its recovery key first."
        }
    }
    $memory = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($memory -and $memory -lt 4GB) {
        '**This PC has under 4 GB of memory.** The Linux installer may run slowly or fail. Lubuntu and Xubuntu need the least.'
    }
}

function Test-RestartPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Test-BitLockerOn {
    $volume = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
        -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue
    [bool]($volume -and $volume.ProtectionStatus -eq 1)
}

# The key that opens the one-time boot menu, by maker.
function Get-BootMenuKey {
    $maker = try { (Get-CimInstance Win32_ComputerSystem).Manufacturer } catch { '' }
    switch -Regex ($maker) {
        'Micro-Star|MSI' { return 'F11' }
        'ASUS' { return 'F8' }
        'Hewlett|HP' { return 'F9' }
        'Acer|Dell|Lenovo|Gigabyte|Toshiba|Razer|Dynabook' { return 'F12' }
    }
    'F12, F11, F9 or Esc'
}

function Suspend-BitLockerForSetup {
    if (Test-BitLockerOn) {
        # Changing boot entries can make BitLocker ask for the recovery key; pause it for a few restarts.
        Write-Log 'BitLocker is on; pausing it for the next 3 restarts.'
        & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 3 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not pause BitLocker. Turn off "Device encryption" in Settings and try again.' }
        return $true
    }
    $false
}

# usbless can restart many times, and turning off Secure Boot makes BitLocker ask for the
# recovery key unless it's paused at that moment. So each restart starts a fresh count.
function Suspend-BitLockerForRestart($State) {
    if (Test-BitLockerOn) {
        [void](Suspend-BitLockerForSetup)
        $State | Add-Member -NotePropertyName BitLockerPaused -NotePropertyValue $true -Force
    } elseif ($State.BitLockerPaused) {
        & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 3 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log 'Could not extend the BitLocker pause.' }
    }
}

function Resume-BitLockerAfterUndo {
    & manage-bde.exe -protectors -enable $env:SystemDrive | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Log 'Turned BitLocker back on.' } else { Write-Log 'Could not turn BitLocker back on; Windows does so itself after a few restarts.' }
}

$PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'

function Get-FastStartup {
    (Get-ItemProperty -Path $PowerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
}

function Disable-FastStartup {
    # Fast Startup leaves Windows half-asleep, which confuses Linux installers.
    Set-ItemProperty -Path $PowerKey -Name HiberbootEnabled -Value 0 -Type DWord
    Write-Log 'Turned off Windows Fast Startup.'
}

function Restore-FastStartup {
    Set-ItemProperty -Path $PowerKey -Name HiberbootEnabled -Value 1 -Type DWord
    Write-Log 'Turned Windows Fast Startup back on.'
}
