# Unit tests for replacing Windows. Like the others, everything that touches the disk or the
# firmware is mocked. Whether a live system really lets go of its disk can only be seen by
# booting one: see docs/TESTING.md for what was run and what wasn't.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1') -WithUsbless
    Mock Write-Log { }
    Mock Get-DiskAttachment { 'internal' }

    function New-Offered {
        New-Entry 'test' 'Test OS' '' '' '#000000' '' @{ Kind = 'ubuntu'; Manual = 'Manual'; FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 6; Steps = @('Erase **{DISK}**.') } }
    }
    function New-WinDisk([int]$Number = 0, [string]$Bus = 'NVMe', [int64]$Size = 500GB, [string]$Name = 'WD  Blue') {
        [pscustomobject]@{ Number = $Number; BusType = $Bus; PartitionStyle = 'GPT'; FriendlyName = $Name; Size = $Size; Guid = "{disk-$Number}" }
    }
    function New-Part([string]$Letter, [int64]$Offset, [int64]$Size, [string]$Type = $BasicDataType, [int]$Disk = 0) {
        [pscustomobject]@{ DiskNumber = $Disk; PartitionNumber = 1; Offset = $Offset; Size = $Size; GptType = $Type; IsSystem = $false; IsBoot = $false
            DriveLetter = if ($Letter) { [char]$Letter } else { [char]0 } }
    }
}

Describe 'Which systems are offered' {
    It 'only offers what was really seen erasing a disk and starting afterwards' {
        @(Get-Catalog | Where-Object FullDisk).Id | Should -Be @('elementary', 'ubuntu', 'zorin', 'fedora', 'debian', 'arch', 'omarchy', 'ultramarine', 'ubuntu-budgie', 'xubuntu', 'ubuntucinnamon', 'edubuntu', 'ubuntustudio')
    }
    It 'has what the install needs for every system it offers' {
        foreach ($distro in Get-Catalog | Where-Object FullDisk) {
            $distro.FullDisk.Word | Should -Not -BeNullOrEmpty
            $distro.FullDisk.Edits.Count | Should -BeGreaterThan 0
            $distro.FullDisk.IsoGB | Should -BeGreaterThan 0
            $distro.FullDisk.Steps | Should -Not -BeNullOrEmpty
        }
    }
    It 'never offers it for someone''s own ISO' {
        (Get-Distro 'custom' 'C:\isos\zorin-17.iso').FullDisk | Should -BeNullOrEmpty
    }
    It 'tells people to erase, and not the opposite, on every system it offers' {
        foreach ($distro in Get-Catalog | Where-Object FullDisk) {
            $text = (Get-Steps $distro 0 ([pscustomobject]@{ FullDisk = $true; DiskName = 'WD Blue'; DiskGB = 500 })).Steps -join ' '
            $text | Should -BeLike '*WD Blue (500 GB)*'
            $text | Should -Not -BeLike "*Don't choose*"
            $text | Should -Not -BeLike '*{DISK}*'
            $text | Should -Not -BeLike '*alongside*'
        }
    }
}

Describe 'Boot config for a full disk' {
    BeforeAll {
        function Edit-With([string]$Family, [string]$Text) {
            $distro = New-Entry 'x' 'X' '' '' '#000000' '' @{ FullDisk = Get-FullDiskBoot $Family }
            Get-EditedBootConfig $distro $Text -FullDisk
        }
    }
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$root\boot\grub" -Force | Out-Null
    }
    It 'asks each family in its own words' {
        (Get-FullDiskBoot 'casper').Word | Should -Be 'toram'
        (Get-FullDiskBoot 'liveboot').Word | Should -Be 'toram'
        (Get-FullDiskBoot 'dracut').Word | Should -Be 'rd.live.ram=1'
        (Get-FullDiskBoot 'archiso').Word | Should -Be 'copytoram'
    }
    It 'adds toram before the --- in Ubuntu''s menu, so it stays out of the installed system' {
        Edit-With 'casper' "menuentry `"Try or Install Ubuntu`" {`n`tlinux`t/casper/vmlinuz  --- quiet splash`n}`n" |
            Should -Be "menuentry `"Try or Install Ubuntu`" {`n`tlinux`t/casper/vmlinuz toram  --- quiet splash`n}`n"
    }
    It 'changes every live entry and leaves others alone' {
        $text = Edit-With 'casper' "linux /casper/vmlinuz --- quiet`nlinux /casper/vmlinuz nomodeset ---`nlinux /boot/memtest.bin`n"
        $text | Should -Be "linux /casper/vmlinuz toram --- quiet`nlinux /casper/vmlinuz toram nomodeset ---`nlinux /boot/memtest.bin`n"
    }
    It 'adds toram to Debian''s entries' {
        Edit-With 'liveboot' "`tlinux`t/live/vmlinuz-6.12 boot=live components quiet" | Should -Be "`tlinux`t/live/vmlinuz-6.12 toram boot=live components quiet"
    }
    It 'adds the word to Fedora''s, once it names the installer partition' {
        $distro = (Get-Catalog | Where-Object Id -eq 'fedora')
        $distro.FullDisk = Get-FullDiskBoot 'dracut'
        Get-EditedBootConfig $distro "linux /x root=live:CDLABEL=F44 rd.live.image" -FullDisk | Should -BeLike "linux /x root=live:LABEL=$InstallerLabel rd.live.ram=1 *umount* rd.live.image"
    }
    It 'finds Pop!_OS''s casper folder, whose name has its version in it' {
        Edit-With 'casper' "`tlinux /casper_pop-os_24.04_amd64_generic_debug_681/vmlinuz.efi boot=casper ---" |
            Should -Be "`tlinux /casper_pop-os_24.04_amd64_generic_debug_681/vmlinuz.efi toram boot=casper ---"
    }
    It 'keeps Fedora''s word for it when it lets go of the disk as it starts' {
        $fedora = Get-Catalog | Where-Object Id -eq 'fedora'
        $edited = Get-EditedBootConfig $fedora "linux /x root=live:CDLABEL=F44 rd.live.image" -FullDisk
        $edited | Should -BeLike '*rd.live.ram=1*'
        $edited | Should -BeLike '*umount -l /run/initramfs/live*'
    }
    It 'copies Omarchy to memory as well, and still lets go of the disk as it starts' {
        $omarchy = Get-Catalog | Where-Object Id -eq 'omarchy'
        $edited = Get-EditedBootConfig $omarchy 'chainloader /x archisobasedir=arch archisosearchuuid=2026-10-19 quiet' -FullDisk
        $edited | Should -BeLike "*archisobasedir=arch copytoram archisolabel=$LiveLabel *umount -l /run/archiso/bootmnt*"
    }
    It 'adds copytoram to Arch''s' {
        Edit-With 'archiso' 'options  archisobasedir=arch archisolabel=USBLINSTALL' | Should -Be 'options  archisobasedir=arch copytoram archisolabel=USBLINSTALL'
    }
    It 'edits nothing unless asked: the usual install stays as it was' {
        $path = "$root\boot\grub\grub.cfg"
        $before = [Text.Encoding]::ASCII.GetBytes("linux /casper/vmlinuz --- quiet`n")
        [IO.File]::WriteAllBytes($path, $before)
        Update-BootConfig (New-Offered) $root
        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($before -join ',')
    }
    It 'writes the word when asked, and says so' {
        $path = "$root\boot\grub\grub.cfg"
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("linux /casper/vmlinuz --- quiet`n"))
        $distro = New-Offered
        Test-FullDiskConfig $distro $root | Should -BeFalse
        Update-BootConfig $distro $root -FullDisk
        [IO.File]::ReadAllText($path) | Should -Be "linux /casper/vmlinuz toram --- quiet`n"
        Test-FullDiskConfig $distro $root | Should -BeTrue
    }
    It 'knows a menu it can edit, and refuses one a new release has changed' {
        $distro = New-Offered
        Test-BootConfigKnown $distro $root -FullDisk | Should -BeFalse
        Set-Content "$root\boot\grub\grub.cfg" 'linux /boot/vmlinuz --- quiet'
        Test-BootConfigKnown $distro $root -FullDisk | Should -BeFalse
        Set-Content "$root\boot\grub\grub.cfg" 'linux /casper/vmlinuz --- quiet'
        Test-BootConfigKnown $distro $root -FullDisk | Should -BeTrue
    }
    It 'does not ask the usual install about a menu full disk needs' {
        Test-BootConfigKnown (New-Offered) $root | Should -BeTrue
    }
    It 'does not take a word that only looks the same' {
        Set-Content "$root\boot\grub\grub.cfg" 'linux /casper/vmlinuz toramdisk --- quiet'
        Test-FullDiskConfig (New-Offered) $root | Should -BeFalse
    }
}

Describe 'Memory for the copy' {
    BeforeEach { Mock Get-MemoryBytes { [int64]16GB } }
    It 'lets through what fits with room left' {
        Get-FullDiskMemoryBlocker (New-Offered) ([int64]6GB) | Should -BeNullOrEmpty
        Get-FullDiskMemoryBlocker (New-Offered) ([int64]12GB) | Should -BeNullOrEmpty
    }
    It 'refuses what would fit but leave no room, with a plain reason' {
        $reason = Get-FullDiskMemoryBlocker (New-Offered) ([int64]12GB + 1)
        $reason | Should -BeLike '*at least 17 GB of memory*Test OS*This PC has 16 GB*next to Windows*'
    }
}

Describe 'Get-FullDiskBlocker' {
    BeforeEach {
        Mock Get-WindowsPartition { New-Part 'C' ([int64]1GB) ([int64]400GB) }
        Mock Get-Disk { New-WinDisk }
        Mock Get-DriveBlocker { }
        Mock Get-WindowsEsp { New-Part '' ([int64]1MB) ([int64]100MB) $EspType }
        Mock Get-MemoryBytes { [int64]16GB }
        Mock Test-SecureBoot { $false }
    }
    It 'lets a suitable PC through' {
        Get-FullDiskBlocker (New-Offered) | Should -BeNullOrEmpty
    }
    It 'refuses a system nobody has shown works' {
        $distro = New-Entry 'x' 'Other OS' '' '' '#000000' '' @{}
        Get-FullDiskBlocker $distro | Should -BeLike "*hasn't shown*Other OS*next to Windows*"
    }
    It 'refuses too little memory before anything is downloaded' {
        Mock Get-MemoryBytes { [int64]8GB }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*at least 10 GB of memory*'
    }
    It 'passes on what stops usbless using C: at all' {
        Mock Get-DriveBlocker { 'The Windows disk uses the old MBR layout.' }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*MBR*'
    }
    It 'refuses a RAID disk, which the installer could not see' {
        Mock Get-Disk { New-WinDisk -Bus 'RAID' }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*RAID*'
    }
    It 'refuses when Windows starts from another disk' {
        Mock Get-WindowsEsp { New-Part '' ([int64]1MB) ([int64]100MB) $EspType -Disk 1 }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*different disk*'
    }
    It 'refuses when the EFI partition cannot be found' {
        Mock Get-WindowsEsp { throw 'Could not find the EFI system partition.' }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*different disk*'
    }
    It 'refuses when another disk has the same name and size, and says why' {
        Mock Get-Disk { if ($null -ne $Number) { New-WinDisk } else { (New-WinDisk), (New-WinDisk -Number 1) } }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike "*more than one disk called WD Blue (500 GB)*wrong one could be erased*next to Windows*"
    }
    It 'still treats names as the same when only their spacing differs' {
        Mock Get-Disk { if ($null -ne $Number) { New-WinDisk } else { (New-WinDisk), (New-WinDisk -Number 1 -Name 'WD Blue') } }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*more than one disk*'
    }
    It 'lets through a disk with the same name and another size, or the same size and another name' {
        Mock Get-Disk { if ($null -ne $Number) { New-WinDisk } else { (New-WinDisk), (New-WinDisk -Number 1 -Size ([int64]1000GB)), (New-WinDisk -Number 2 -Name 'Samsung') } }
        Get-FullDiskBlocker (New-Offered) | Should -BeNullOrEmpty
    }
    It 'refuses a disk too small for Linux' {
        Mock Get-Disk { New-WinDisk -Size ([int64]20GB) }
        Get-FullDiskBlocker (New-Offered) | Should -BeLike '*too small*'
    }
    It 'refuses a system Secure Boot would stop' {
        $distro = New-Offered
        $distro.SecureBootOff = $true
        Mock Test-SecureBoot { $true }
        Get-FullDiskBlocker $distro | Should -BeLike '*Secure Boot*'
    }
}

Describe 'Get-VolumesOnDisk' {
    BeforeEach {
        Mock Get-WindowsPartition { New-Part 'C' ([int64]1GB) ([int64]400GB) }
        Mock Get-Partition {
            New-Part '' ([int64]1MB) ([int64]100MB) $EspType
            New-Part '' ([int64]200MB) ([int64]16MB) $MsrType
            New-Part 'C' ([int64]1GB) ([int64]400GB)
            New-Part '' ([int64]401GB) ([int64]1GB) $RecoveryType
            New-Part 'D' ([int64]402GB) ([int64]90GB)
            New-Part '' ([int64]492GB) ([int64]5GB)
            New-Part '' ([int64]497GB) ([int64]3GB)
        }
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'Games' } }
        Mock Get-PartitionSignature { if ([int64]$Partition.Offset -eq [int64]492GB) { 'bitlocker' } }
        Mock Test-LinuxSignature { $false }
        Mock Test-DriveEncrypted { $Letter -eq 'D' }
    }
    It 'names everything that would go, and leaves out what is Windows'' own' {
        $volumes = @(Get-VolumesOnDisk 0)
        $volumes.What | Should -Be @('drive C:', 'drive D:', 'a locked BitLocker drive', 'a partition with no letter')
        $volumes[0].Name | Should -Be 'Windows'
        $volumes[1].Name | Should -Be 'Games'
        $volumes[1].SizeGB | Should -Be 90
        $volumes[1].Encrypted | Should -BeTrue
    }
    It 'makes a line of them that says their names and sizes' {
        $line = Format-VolumeList @(Get-VolumesOnDisk 0)
        $line | Should -BeLike '**drive C:** (Windows, 400 GB), **drive D:** (Games, 90 GB)*'
    }
    It 'calls a Linux partition what it is' {
        Mock Test-LinuxSignature { [int64]$Partition.Offset -eq [int64]497GB }
        (@(Get-VolumesOnDisk 0)[-1]).What | Should -Be 'a Linux partition'
    }
}

Describe 'Get-FullDiskPlan' {
    BeforeEach {
        Mock Get-Distro { New-Offered }
        Mock Get-FullDiskBlocker { }
        Mock Get-WindowsPartition { New-Part 'C' ([int64]1GB) ([int64]400GB) }
        Mock Get-Disk {
            if ($null -ne $Number) { New-WinDisk } else { (New-WinDisk), (New-WinDisk -Number 1 -Size ([int64]1000GB) -Name 'Samsung T7') }
        }
        Mock Get-VolumesOnDisk { [pscustomobject]@{ What = 'drive C:'; Name = 'Windows'; SizeGB = 400; Encrypted = $false }, [pscustomobject]@{ What = 'drive D:'; Name = ''; SizeGB = 90; Encrypted = $false } }
        Mock Get-DriveSpace { [pscustomobject]@{ Id = $Target; Title = 'Drive C:' } }
        Mock Get-SystemsOnWindowsEsp { }
    }
    It 'says which other systems stop starting, and does not promise other disks are safe' {
        Mock Get-SystemsOnWindowsEsp { 'Linux Mint', 'Windows on drive D:' }
        $plan = Get-FullDiskPlan 'ubuntu' ''
        $plan.StopsStarting | Should -Be @('Linux Mint', 'Windows on drive D:')
        $text = $plan.Points -join ' '
        $text | Should -BeLike '*These stop starting:** **Linux Mint**, **Windows on drive D:***EFI partition*'
        $text | Should -Not -BeLike '*Other disks stay as they are*'
        $text | Should -BeLike "*What's stored on other disks stays:** **Samsung T7***"
    }
    It 'adds no empty line when nothing else starts from there' {
        $plan = Get-FullDiskPlan 'ubuntu' ''
        @($plan.StopsStarting).Count | Should -Be 0
        @($plan.Points).Count | Should -Be 4
    }
    It 'refuses when it cannot read what else starts from there' {
        Mock Get-SystemsOnWindowsEsp { throw 'blocked' }
        $plan = Get-FullDiskPlan 'ubuntu' ''
        $plan.Blocker | Should -BeLike "*couldn't read*EFI partition*next to Windows*"
        @($plan.Points).Count | Should -Be 0
    }
    It 'names the disk, what goes with it, and the disk that stays' {
        $plan = Get-FullDiskPlan 'ubuntu' ''
        $plan.DiskName | Should -Be 'WD Blue'
        $plan.DiskGB | Should -Be 500
        $text = $plan.Points -join ' '
        $text | Should -BeLike '*drive C:** (Windows, 400 GB), **drive D:** (90 GB)*'
        $text | Should -BeLike '*BitLocker recovery key*nothing left to unlock*'
        $text | Should -BeLike '*Other disks stay as they are:** **Samsung T7** (1000 GB)*'
        $text | Should -BeLike '*Nothing is erased yet*Undo works until then*'
    }
    It 'says why not, and nothing else, when it cannot be done' {
        Mock Get-FullDiskBlocker { 'Not enough memory.' }
        $plan = Get-FullDiskPlan 'ubuntu' ''
        $plan.Blocker | Should -Be 'Not enough memory.'
        $plan.Target | Should -BeNullOrEmpty
        @($plan.Points).Count | Should -Be 0
    }
    It 'puts the installer back on C: when the chosen drive is on another disk' {
        Mock Resolve-Target { [pscustomobject]@{ IsWindows = $false; Partition = New-Part 'E' ([int64]1GB) ([int64]300GB) -Disk 1 } }
        (Get-FullDiskPlan 'ubuntu' 'volume:{disk-1}:1073741824').Target.Id | Should -Be ''
    }
    It 'keeps a chosen drive on Windows'' disk' {
        Mock Resolve-Target { [pscustomobject]@{ IsWindows = $false; Partition = New-Part 'D' ([int64]402GB) ([int64]90GB) } }
        (Get-FullDiskPlan 'ubuntu' 'volume:{disk-0}:431644213248').Target.Id | Should -Be 'volume:{disk-0}:431644213248'
    }
    It 'changes nothing on the PC' {
        Mock New-Partition { throw 'no' }; Mock Remove-Partition { throw 'no' }; Mock Resize-Partition { throw 'no' }; Mock Format-Volume { throw 'no' }
        { Get-FullDiskPlan 'ubuntu' '' } | Should -Not -Throw
        Should -Invoke New-Partition -Times 0; Should -Invoke Remove-Partition -Times 0; Should -Invoke Resize-Partition -Times 0; Should -Invoke Format-Volume -Times 0
    }
}

Describe 'Get-SystemsOnWindowsEsp' {
    BeforeEach {
        $script:esp = Join-Path $TestDrive ([guid]::NewGuid())
        foreach ($folder in 'Microsoft', 'Boot', 'usbless', 'ubuntu', 'Dell', 'refind') { New-Item -ItemType Directory -Path "$esp\EFI\$folder" -Force | Out-Null }
        New-Item -ItemType File -Path "$esp\EFI\ubuntu\shimx64.efi", "$esp\EFI\usbless\grubx64.efi", "$esp\EFI\Dell\update.efi", "$esp\EFI\Boot\grubx64.efi", "$esp\EFI\refind\refind_x64.efi" | Out-Null
        Mock Get-WindowsEsp { [pscustomobject]@{ Guid = '{esp}' } }
        Mock Use-Esp { & $Action $script:esp }
        Mock Invoke-Bcdedit { '' }
        Mock Get-BootEntries {
            [pscustomobject]@{ Description = 'Windows Boot Manager'; PartitionGuid = '{esp}'; Path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
            [pscustomobject]@{ Description = 'Linux Mint'; PartitionGuid = '{esp}'; Path = '\EFI\ubuntu\shimx64.efi' }
            [pscustomobject]@{ Description = 'Elsewhere'; PartitionGuid = '{other}'; Path = '\EFI\refind\refind_x64.efi' }
        }
    }
    It 'names a Linux by its startup entry, a folder by its name, and leaves out Windows, usbless and makers'' tools' {
        Get-SystemsOnWindowsEsp | Should -Be @('refind', 'Linux Mint')
    }
    It 'lets a failure through, so that nobody is told it is safe' {
        Mock Use-Esp { throw 'blocked' }
        { Get-SystemsOnWindowsEsp } | Should -Throw 'blocked'
    }
    It 'finds another Windows in the startup menu, whichever language it is in' {
        Mock Invoke-Bcdedit {
@'

Windows-Startladeprogramm
-------------------------
Bezeichner              {current}
device                  partition=C:
path                    \Windows\system32\winload.efi
description             Windows 11

Windows-Startladeprogramm
-------------------------
Bezeichner              {11111111-2222-3333-4444-555555555555}
device                  partition=D:
path                    \Windows\system32\winload.efi
description             Windows 10

Windows-Startladeprogramm
-------------------------
Bezeichner              {22222222-2222-3333-4444-555555555555}
device                  ramdisk=[\Device\HarddiskVolume5]\Recovery\WindowsRE\Winre.wim
path                    \windows\system32\winload.efi
description             Windows Recovery Environment
'@
        }
        Get-OtherWindowsLoaders | Should -Be 'Windows on drive D:'
        Get-SystemsOnWindowsEsp | Should -Contain 'Windows on drive D:'
    }
}

Describe 'Get-Plan for the installer alone' {
    BeforeAll {
        function New-Space([int64]$TailFree, [int]$UsableGB) {
            [pscustomobject]@{
                Partition = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = [int64]200GB }
                TailFree = $TailFree; UsableGB = $UsableGB; Kind = 'volume'; Name = 'C:'; Letter = 'C'
            }
        }
    }
    It 'makes room for the installer and leaves nothing for Linux' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 150 }
        $plan = Get-Plan 0 8
        $plan.LinuxGB | Should -Be 0
        $plan.InstallerOffset | Should -Be ([int64]193GB)
        $plan.FreeStart | Should -Be ([int64]201GB)
        $plan.NewWindowsSize | Should -Be ([int64]192GB)
    }
    It 'does not ask for Linux''s usual room' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 9 }
        { Get-Plan 0 8 } | Should -Not -Throw
    }
    It 'says how much more the installer needs' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 5 }
        { Get-Plan 0 8 } | Should -Throw '*for the installer*3 GB more*'
    }
}

Describe 'Invoke-Install with -FullDisk' {
    BeforeEach {
        $Sync.Gate = New-Object Usbless.CancelGate
        Mock Test-System { }
        Mock Get-InstallStatus { 'none' }
        Mock Get-Distro { New-Offered }
        Mock Assert-SecureBootAllows { }
        Mock Assert-FirmwareAccess { }
        Mock Assert-DriveUsable { }
        Mock Assert-StateRoom { }
        Mock Get-FullDiskBlocker { }
        Mock Test-Path { $true }
        Mock Read-Iso { [pscustomobject]@{ Letter = 'Z'; Bytes = [int64]6GB; InstallerGB = 7 } }
        Mock Get-MemoryBytes { [int64]16GB }
        Mock Test-BootConfigKnown { $true }
        Mock Get-Plan { [pscustomobject]@{ DiskNumber = 0; Kind = 'volume'; Letter = 'C'; TargetOffset = [int64]1GB; LinuxGB = 0 } }
        Mock Use-Esp { }
        Mock Get-Disk { New-WinDisk }
        Mock Get-WindowsPartition { New-Part 'C' ([int64]1GB) ([int64]400GB) }
        Mock Get-LinuxLoaders { }
        Mock Get-Partition { }
        Mock Get-LinuxPartitions { }
        Mock Get-FastStartup { 1 }
        Mock Save-State { }
        Mock Suspend-BitLockerForSetup { $false }
        Mock Disable-FastStartup { }
        Mock New-LinuxSpace { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4 } }
        Mock Test-AlongsideFindsLinux { $true }
        Mock Restore-RoomSettings { }
        Mock Get-DriveLetter { 'H' }
        Mock Copy-Installer { }
        Mock Update-BootConfig { }
        Mock Test-FullDiskConfig { $true }
        Mock Register-Installer { 7 }
        Mock Invoke-Cleanup { }
        Mock Dismount-DiskImage { }
    }
    It 'makes only the installer, asks for the copy to memory and records what it did' {
        Invoke-Install 'ubuntu' 'C:\u.iso' 60 '' '' -FullDisk
        Should -Invoke Get-Plan -ParameterFilter { $LinuxGB -eq 0 -and $InstallerGB -eq 7 }
        Should -Invoke New-LinuxSpace -ParameterFilter { $Strategy -eq 'freespace' }
        Should -Invoke Update-BootConfig -ParameterFilter { $FullDisk }
        Should -Invoke Save-State -ParameterFilter { $State.FullDisk -eq $true -and $State.LinuxGB -eq 0 }
        Should -Invoke Test-AlongsideFindsLinux -Times 0
    }
    It 'leaves the usual install as it was' {
        Invoke-Install 'ubuntu' 'C:\u.iso' 60 '' ''
        Should -Invoke Get-Plan -ParameterFilter { $LinuxGB -eq 60 }
        Should -Invoke Update-BootConfig -ParameterFilter { -not $FullDisk }
        Should -Invoke Save-State -ParameterFilter { $State.FullDisk -eq $false }
        Should -Invoke Get-FullDiskBlocker -Times 0
    }
    It 'refuses a system whose steps do not cover a second disk, before downloading' {
        Mock Get-Distro { New-Entry 'x' 'Other OS' '' '' '#000000' '' @{ Steps = @('Click.') } }
        Mock Resolve-Target { [pscustomobject]@{ Partition = New-Part 'E' ([int64]1GB) ([int64]300GB) -Disk 1 } }
        { Invoke-Install 'x' '' 60 'volume:{disk-1}:1073741824' '' } | Should -Throw "*second disk*"
        Should -Invoke Save-State -Times 0
    }
    It 'refuses before downloading, and changes nothing' {
        Mock Get-FullDiskBlocker { 'Not enough memory.' }
        { Invoke-Install 'ubuntu' '' 60 '' '' -FullDisk } | Should -Throw 'Not enough memory.'
        Should -Invoke Save-State -Times 0
        Should -Invoke New-LinuxSpace -Times 0
    }
    It 'refuses an ISO too big for this PC''s memory, before the disk changes' {
        Mock Read-Iso { [pscustomobject]@{ Letter = 'Z'; Bytes = [int64]13GB; InstallerGB = 14 } }
        { Invoke-Install 'ubuntu' 'C:\u.iso' 60 '' '' -FullDisk } | Should -Throw '*memory*'
        Should -Invoke Save-State -Times 0
        Should -Invoke New-LinuxSpace -Times 0
        Should -Invoke Invoke-Cleanup -Times 0
    }
    It 'refuses a menu it does not know, before the disk changes' {
        Mock Test-BootConfigKnown { $false }
        { Invoke-Install 'ubuntu' 'C:\u.iso' 60 '' '' -FullDisk } | Should -Throw '*next to Windows*'
        Should -Invoke New-LinuxSpace -Times 0
    }
    It 'undoes everything when the menu could not be changed' {
        Mock Test-FullDiskConfig { $false }
        { Invoke-Install 'ubuntu' 'C:\u.iso' 60 '' '' -FullDisk } | Should -Throw '*startup menu*'
        Should -Invoke Invoke-Cleanup -Times 1
        Should -Invoke Register-Installer -Times 0
    }
}

Describe 'Coming back to Windows without erasing' {
    BeforeAll {
        function New-FullDiskState {
            [pscustomobject]@{
                Distro = 'Ubuntu'; DistroId = 'ubuntu'; Strategy = 'freespace'; LinuxGB = 0; FullDisk = $true; DiskNumber = 0
                WindowsShrunk = $true; Partitions = @(); BootNumber = 7; IsoPath = 'C:\u.iso'; Copied = $true
                RestartedAt = '2026-01-01T10:00:00'; LoadersBefore = @('\EFI\Microsoft\Boot\bootmgfw.efi'); LinuxBefore = @()
                FastStartupWasOn = $true; BitLockerPaused = $true; InstallerNextToWindows = $true
                DiskGuid = '{disk-0}'; DiskName = 'WD Blue'; DiskGB = 500; OnWindowsDisk = $true
                TargetKind = 'volume'; TargetLetter = 'C'; TargetOffset = [int64]1GB; AlongsideOk = $null
            }
        }
    }
    BeforeEach {
        Mock Read-State { New-FullDiskState }
        Mock Get-StateDisk { 0 }
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\Microsoft\Boot\bootmgfw.efi' } }
        Mock Get-Partition { }
        Mock Get-LinuxPartitions { }
        Mock Get-UsblessPartitions { [pscustomobject]@{ Partition = (New-Part 'H' ([int64]201GB) ([int64]8GB)); Label = $InstallerLabel; Letter = 'H' } }
        Mock Get-FirmwareEntries { @(7) }
        Mock Get-BcdEntries { }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*BOOTX64.EFI' }
    }
    It 'is a setup like any other: ready, and not installed' {
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'counts as coming back once Windows has started again' {
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]'2026-01-01T10:05:00' } }
        Test-CameBack (New-FullDiskState) | Should -BeTrue
    }
    It 'gives the same help as any other install that came back' {
        Mock Test-EntryDropped { $false }
        Mock Test-BootNextIgnored { $false }
        Mock Test-SecureBoot { $false }
        Mock Get-BootMenuKey { 'F12' }
        ((Get-ReturnedHelp).Steps -join ' ') | Should -BeLike '*Ubuntu installer (usbless)*'
    }
    It 'shows the steps for erasing, because that is what this setup is for' {
        $steps = Get-StateSteps
        $steps.FullDisk | Should -BeTrue
        ($steps.Steps -join ' ') | Should -BeLike '*Erase*WD Blue (500 GB)*'
    }
    It 'gives every byte back to Windows on Undo, and turns everything back on' {
        Mock Get-FirmwareEntries { }
        Mock Use-Esp { }
        Mock Remove-PartitionAt { }
        Mock Get-RecordedPartitions { }
        Mock Get-PartitionAt { New-Part 'C' ([int64]1GB) ([int64]192GB) }
        Mock Get-WindowsPartition { New-Part 'C' ([int64]1GB) ([int64]192GB) }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]200GB } }
        Mock Resize-Partition { }
        Mock Restore-FastStartup { }
        Mock Resume-BitLockerAfterUndo { }
        Mock Remove-Item { }
        Mock Test-LinuxInstalled { $false }
        Mock Set-Status { }
        Invoke-Cleanup
        Should -Invoke Remove-PartitionAt -Times 1
        Should -Invoke Resize-Partition -ParameterFilter { $Size -eq [int64]200GB }
        Should -Invoke Restore-FastStartup -Times 1
        Should -Invoke Resume-BitLockerAfterUndo -Times 1
    }
}

Describe 'Get-FullDiskSteps' {
    It 'says what to do if the disk is not offered, in place of forcing it' {
        $steps = Get-FullDiskSteps (New-Offered) ([pscustomobject]@{ DiskName = 'WD Blue'; DiskGB = 500 })
        ($steps.Notes -join ' ') | Should -BeLike "*WD Blue (500 GB)** isn't offered*don't force it*Windows, which is still there*"
        $steps.Steps | Should -Be @('Erase **WD Blue (500 GB)**.')
    }
    It 'still has words for a system since taken out of the catalog' {
        $distro = New-Entry 'x' 'X' '' '' '#000000' '' @{}
        ((Get-FullDiskSteps $distro ([pscustomobject]@{ DiskName = 'WD Blue'; DiskGB = 500 })).Steps -join ' ') | Should -BeLike '*erase the disk*WD Blue (500 GB)*'
    }
    It 'is what Get-Steps gives for a setup that replaces Windows, and only then' {
        $distro = Get-Catalog | Where-Object Id -eq 'ubuntu'
        ((Get-Steps $distro 60).Steps -join ' ') | Should -BeLike "*Don't choose **Erase disk***"
    }
}
