function Invoke-Bcdedit {
    # Windows PowerShell turns a native program's stderr into a terminating error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $output = & bcdedit.exe @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($args -join ' ') failed: $output" }
    $output
}

# Opens Windows' EFI system partition for a moment.
function Use-Esp([scriptblock]$Action) {
    $letter = [char[]](90..68) | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
    if (-not $letter) { throw 'Every drive letter is in use, so the EFI system partition cannot be opened. Remove a network drive or USB drive and try again.' }
    & mountvol.exe "$($letter):" /s | Out-Null
    if (-not (Test-Path "$($letter):\EFI")) {
        # Under 'Stop', a native program's stderr would replace this message.
        try { & mountvol.exe "$($letter):" /d 2>$null | Out-Null } catch { }
        throw 'Could not open the EFI system partition. Security software may be blocking it: turn that off for a moment and try again.'
    }
    try { & $Action "$($letter):\" } finally { & mountvol.exe "$($letter):" /d | Out-Null }
}

function Get-BootEntries { [Usbless.Firmware]::ListEntries() }

function Remove-FirmwareEntry([int]$Number) { [Usbless.Firmware]::DeleteBootEntry($Number) }

# Looks on every disk: Windows on a second drive often starts from the first drive's EFI partition.
# The one this Windows started from comes first, which is the one Use-Esp opens, so the boot loader
# and its startup entry can't end up on different partitions. A PC can have two Windows Boot Manager
# entries, from a second Windows or a cloned disk, and the first of them may not be this Windows'.
function Get-WindowsEsp {
    $partitions = @(Get-Partition | Where-Object GptType -eq $EspType)
    $esp = $partitions | Where-Object IsSystem | Select-Object -First 1
    if (-not $esp) {
        $windows = @(try { Get-BootEntries } catch { @() }) |
            Where-Object { $_.Path -like '\EFI\Microsoft\*' } | Select-Object -First 1
        if ($windows) { $esp = $partitions | Where-Object Guid -eq $windows.PartitionGuid | Select-Object -First 1 }
    }
    if (-not $esp) {
        $disk = (Get-WindowsPartition).DiskNumber
        $esp = $partitions | Where-Object DiskNumber -eq $disk | Select-Object -First 1
    }
    if (-not $esp) { throw 'Could not find the EFI system partition.' }
    $esp
}

# Windows' EFI partition is small, and other systems may have filled it. $LinuxMB is what the Linux
# installer will add there later, for those whose installer doesn't notice when it runs out. usbless's own
# boot loader doesn't count against it, because it's replaced by what's about to be copied.
function Get-OwnLoaderBytes([string]$Root) {
    [int64]$bytes = 0
    foreach ($name in $EspFolders) {
        $own = Join-Path $Root $name
        if (Test-Path -LiteralPath $own) { $bytes += [int64](Get-ChildItem -LiteralPath $own -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum }
    }
    $bytes
}

function Assert-EspRoom([string]$Root, [string]$Source, [int]$LinuxMB = 0) {
    $needed = (Get-ChildItem -LiteralPath $Source -Filter '*.efi' -Force | Measure-Object -Property Length -Sum).Sum + 1MB + [int64]$LinuxMB * 1MB
    $free = ([IO.DriveInfo]$Root).AvailableFreeSpace + (Get-OwnLoaderBytes $Root)
    if ($free -lt $needed) {
        throw ('The EFI system partition is too full: the startup files need {0:N0} MB and {1:N0} MB is free. Remove boot files from other systems and try again.' -f ($needed / 1MB), ($free / 1MB))
    }
}

# Security software can block this partition. Finding out now costs nothing; after the disk has changed it costs a lot.
function Assert-EspWritable([string]$Root) {
    $probe = Join-Path $Root 'EFI\usbless-write-test.tmp'
    try {
        Set-Content -LiteralPath $probe -Value 'usbless'
        Remove-Item -LiteralPath $probe -Force
    } catch {
        throw "Couldn't write to the EFI system partition ($($_.Exception.Message)). Security software may be blocking it: turn that off for a moment and try again."
    }
}

# The boot config files a system's boot loader reads, on the ISO or the installer partition.
function Get-BootConfigFiles($Distro, [string]$Root, [switch]$FullDisk) {
    $patterns = @($Distro.BootConfigs)
    if ($FullDisk) { $patterns = @($patterns + @($Distro.FullDisk.Configs) | Where-Object { $_ } | Select-Object -Unique) }
    foreach ($pattern in $patterns) { if ($pattern) { Get-Item -Path (Join-Path $Root $pattern) -Force -ErrorAction SilentlyContinue } }
}

# Latin-1 keeps every byte as it was. GRUB chokes on a byte order mark, and menu titles aren't always ASCII.
function Read-BootConfig([string]$Path) { [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path)) }

function Get-EditedBootConfig($Distro, [string]$Text, [switch]$FullDisk) {
    if ($Distro.BootEdits) {
        foreach ($edit in $Distro.BootEdits.GetEnumerator()) { $Text = $Text -replace $edit.Key, $edit.Value }
    }
    if ($FullDisk) {
        foreach ($edit in $Distro.FullDisk.Edits.GetEnumerator()) { $Text = $Text -replace $edit.Key, $edit.Value }
    }
    $Text
}

# Whether this ISO's boot files are the ones usbless knows how to edit. The first edit is what points the
# live system at the installer partition, or stops casper taking Linux's space, so usbless can't do without it.
# A new release could change this, and it's better found before the disk changes.
function Test-BootConfigKnown($Distro, [string]$Root, [switch]$FullDisk) {
    $known = -not $Distro.BootEdits
    if ($Distro.BootEdits) {
        $first = @($Distro.BootEdits.Keys)[0]
        foreach ($file in @(Get-BootConfigFiles $Distro $Root)) {
            if ((Read-BootConfig $file.FullName) -match $first) { $known = $true; break }
        }
    }
    if (-not $known -or -not $FullDisk) { return $known }
    # On the ISO, whose config has none of usbless's changes yet, so the result is what really counts.
    foreach ($file in @(Get-BootConfigFiles $Distro $Root -FullDisk)) {
        $edited = Get-EditedBootConfig $Distro (Read-BootConfig $file.FullName) -FullDisk
        if ($edited -match "(^|\s)$([regex]::Escape($Distro.FullDisk.Word))(\s|$)") { return $true }
    }
    $false
}

# Whether the installer partition's menu really does ask for the copy to memory. Without it, the
# steps would send someone to an installer that can't do what they've been told it will.
function Test-FullDiskConfig($Distro, [string]$Root) {
    foreach ($file in @(Get-BootConfigFiles $Distro $Root -FullDisk)) {
        if ((Read-BootConfig $file.FullName) -match "(^|\s)$([regex]::Escape($Distro.FullDisk.Word))(\s|$)") { return $true }
    }
    $false
}

# Live systems that look for their USB stick by name wouldn't find the installer partition,
# whose FAT32 label is short and fixed. So the copied config, per the catalog, names that
# label instead. Casper's gets the word that stops it making a partition. Shim only checks the
# signatures of programs, so this is safe with Secure Boot.
# With -FullDisk it also asks the live system to copy itself to memory, per the catalog.
function Update-BootConfig($Distro, [string]$Root, [switch]$FullDisk) {
    if (-not $Distro.BootEdits -and -not $FullDisk) { return }
    foreach ($file in @(Get-BootConfigFiles $Distro $Root -FullDisk:$FullDisk)) {
        $text = Read-BootConfig $file.FullName
        $edited = Get-EditedBootConfig $Distro $text -FullDisk:$FullDisk
        if ($edited -ceq $text) { continue }
        # Copied from a read-only ISO, so it may have come out read-only.
        $file.IsReadOnly = $false
        [IO.File]::WriteAllBytes($file.FullName, [Text.Encoding]::GetEncoding(28591).GetBytes($edited))
        Write-Log "Changed $($file.Name) for starting from the installer partition."
    }
}

# What goes in grub.cfg next to the boot loader, which is how it finds the installer partition.
function Get-EspGrubConfig($Distro) {
    if ($Distro.GrubDir) {
        return @(
            "search --no-floppy --label --set=root $InstallerLabel"
            "set prefix=(`$root)/$($Distro.GrubDir)"
            'configfile $prefix/grub.cfg')
    }
    @(
        'search --no-floppy --file --set=root /.disk/info'
        'set prefix=($root)/boot/grub'
        'configfile $prefix/grub.cfg')
}

# systemd-boot only reads its menu and kernels from its own partition, and they don't fit on
# Windows' EFI partition. So what starts first is the ISO's EFI Shell, whose script finds the
# installer partition and starts systemd-boot there. Neither is signed: these need Secure Boot off.
function Get-EspShellScript($Distro) {
    $marker = $Distro.Live -replace '/', '\'
    @(
        '@echo -off'
        'for %a in 0 1 2 3 4 5 6 7 8 9 A B C D E F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F'
        "  if exist fs%a:\$marker then"
        '    fs%a:'
        '    \EFI\BOOT\BOOTx64.EFI'
        '  endif'
        'endfor')
}

# Fills \EFI\usbless from the installer partition's \EFI\BOOT at $Source.
function Copy-EspLoader($Distro, [string]$Source, [string]$Folder) {
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    if ($Distro.EspShell) {
        $partition = Split-Path (Split-Path $Source -Parent) -Parent
        Copy-Item -LiteralPath (Join-Path $partition $Distro.EspShell) -Destination (Join-Path $Folder 'BOOTX64.EFI') -Force
        Set-Content -LiteralPath (Join-Path $Folder 'startup.nsh') -Encoding ASCII -Value (Get-EspShellScript $Distro)
        return
    }
    Get-ChildItem -LiteralPath $Source -Force | Where-Object Extension -eq '.efi' | Copy-Item -Destination $Folder -Force
    Set-Content -LiteralPath (Join-Path $Folder 'grub.cfg') -Encoding ASCII -Value (Get-EspGrubConfig $Distro)
}

# GRUB starts the first partition it finds with /.disk/info, and usbless can't choose the order, so
# a USB installer left plugged in, or another tool's leftovers, could start instead of usbless's.
function Get-OtherInstallers {
    foreach ($volume in @(Get-Volume)) {
        if ($volume.DriveType -eq 'CD-ROM' -or $volume.FileSystemLabel -in $InstallerLabels -or -not $volume.Path) { continue }
        $found = try { [IO.File]::Exists("$($volume.Path).disk\info") } catch { $false }
        if (-not $found) { continue }
        $usb = $volume.DriveType -eq 'Removable' -or $(try { ($volume | Get-Partition | Get-Disk).BusType -eq 'USB' } catch { $false })
        $name = if ($volume.DriveLetter) { "drive $($volume.DriveLetter):" } elseif ($volume.FileSystemLabel) { "the $($volume.FileSystemLabel) partition" } else { 'an unnamed partition' }
        [pscustomobject]@{ Name = $name; Usb = $usb }
    }
}

# Puts the installer in the startup menu. Many firmwares (MSI's included) only start
# files from the EFI system partition, and some delete entries that point anywhere
# else, so the installer's signed boot loader is copied to \EFI\usbless there. The config
# built into Ubuntu's signed GRUB finds the installer partition by its /.disk/info file,
# on any disk the firmware has started; grub.cfg here is only its last resort, though
# Fedora's GRUB does read it first. So the loader stays on Windows' EFI partition, the one
# this firmware is known to start, wherever Linux goes. Safe to run again: old usbless entries
# are replaced.
function Register-Installer([string]$Name, $Distro) {
    Set-Status 'Adding the installer to the startup menu...'
    $installer = Get-UsblessPartitions | Where-Object { $_.Label -in $InstallerLabels } | Select-Object -First 1
    $letter = if (-not $installer) { $null } elseif ($installer.Letter) { $installer.Letter } else { Get-DriveLetter $installer.Partition }
    if (-not $letter -or -not (Test-Path -LiteralPath "$($letter):\EFI\BOOT\BOOTX64.EFI")) {
        throw 'The installer partition is missing or incomplete. Undo the changes and install again.'
    }
    # An installer copied by an older build gets what's changed since.
    Update-BootConfig $Distro "$($letter):\"
    $source = "$($letter):\EFI\BOOT"
    Use-Esp {
        param($root)
        Assert-EspRoom $root $source
        foreach ($old in $EspFolders -ne $EspFolder) {
            $path = Join-Path $root $old
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        Copy-EspLoader $Distro $source (Join-Path $root $EspFolder)
    }
    Write-Log "Copied the installer's boot loader to \$EspFolder on the EFI system partition."

    foreach ($number in @(Get-FirmwareEntries)) { [Usbless.Firmware]::DeleteBootEntry($number) }
    $esp = Get-WindowsEsp
    $sector = (Get-Disk -Number $esp.DiskNumber).LogicalSectorSize
    $number = [Usbless.Firmware]::CreateBootEntry("$Name installer $EntryMarker", $esp.PartitionNumber,
        [int64]($esp.Offset / $sector), [int64]($esp.Size / $sector), $esp.Guid, "\$EspFolder\BOOTX64.EFI")
    Write-Log ('Added startup entry Boot{0:X4}.' -f $number)
    $number
}

function Clear-BootOnce { [Usbless.Firmware]::ClearBootNext() }

function Test-FirmwareAccess { [Usbless.Firmware]::CheckAccess() }

# The startup entry is added after the disk has changed, so find out now if it can't be.
function Assert-FirmwareAccess {
    try { Test-FirmwareAccess } catch {
        throw "usbless can't change this PC's startup menu, so it couldn't start a Linux installer. Nothing has been changed. $($_.Exception.GetBaseException().Message)"
    }
}

function Set-BootOnce([int]$Number) {
    # Only the next restart goes to the installer; after that Windows is the default again.
    [Usbless.Firmware]::SetBootNext($Number)
    Write-Log ('The next restart starts Boot{0:X4}.' -f $Number)
}
