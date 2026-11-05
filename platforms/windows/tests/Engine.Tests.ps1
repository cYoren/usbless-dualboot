# Unit tests for the engine, run by CI on Windows PowerShell 5.1 (Pester 5).
# Everything that touches the disk, the firmware or the network is mocked: these must be
# safe to run on any PC. Build first, because they load usbless.exe for its C# types.
#
#   dotnet build -c Release
#   Invoke-Pester tests

BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1') -WithUsbless
    Mock Write-Log { }
    Mock Get-DiskAttachment { 'internal' }
}

Describe 'Catalog' {
    BeforeAll { $catalog = @(Get-Catalog) }

    It 'marks the systems that need Secure Boot off' {
        @($catalog | Where-Object SecureBootOff).Id | Should -Be @('pop', 'cachyos', 'arch', 'omarchy')
    }
    It 'has unique ids' {
        ($catalog.Id | Sort-Object -Unique).Count | Should -Be $catalog.Count
    }
    It 'gives every system what the app needs' {
        foreach ($distro in $catalog) {
            $distro.Name | Should -Not -BeNullOrEmpty
            $distro.Source | Should -Not -BeNullOrEmpty
            $distro.Note | Should -Not -BeNullOrEmpty
            $distro.Color | Should -Match '^#[0-9A-Fa-f]{6}$'
            $distro.Strategy | Should -BeIn @('freespace', 'prepared')
            $distro.Kind | Should -BeIn @('ubuntu', 'mint', 'pop', 'elementary', 'zorin', 'debian', 'fedora', 'ultramarine', 'cachyos', 'arch', 'omarchy')
        }
    }
    # Letter-mark rendering is checked in the real native UI. The old bundled
    # artwork/file check no longer applies, and private theme reflection is not
    # an engine contract.
    It 'tells people what to click, whichever installer it is' {
        foreach ($distro in $catalog) {
            if ($distro.Strategy -eq 'prepared') { $distro.Mode | Should -Not -BeNullOrEmpty }
            else { $distro.Manual | Should -Not -BeNullOrEmpty }
        }
    }
    It 'makes an entry for a custom ISO from its file name' {
        (Get-Distro 'custom' 'C:\isos\zorin-17.iso').Name | Should -Be 'zorin-17'
    }
    It 'leaves out the systems whose ISO has a file FAT32 cannot hold, without a second partition' {
        $catalog.Id | Should -Not -Contain 'kubuntu'
    }
    It 'only gives Omarchy a second partition' {
        @($catalog | Where-Object LiveFiles).Id | Should -Be @('omarchy')
    }
    It 'lets Omarchy replace Windows with BitLocker on: its installer only checks that for free space' {
        $omarchy = $catalog | Where-Object Id -eq 'omarchy'
        $omarchy.NoBitLocker | Should -BeTrue
        $omarchy.FullDisk | Should -Not -BeNullOrEmpty
    }
    It 'edits the boot files of the systems that need it, with the edit they cannot start without first' {
        foreach ($distro in $catalog | Where-Object BootEdits) {
            $distro.BootConfigs | Should -Not -BeNullOrEmpty
            $label = if ($distro.LiveFiles) { $LiveLabel } else { $InstallerLabel }
            if ($distro.Live) { @($distro.BootEdits.Values)[0] | Should -Match "=$label(\s|$)" }
        }
    }
    It 'stops casper making a partition for everything that starts with it, including a chosen ISO' {
        foreach ($distro in @($catalog | Where-Object Kind -in @('ubuntu', 'mint', 'pop', 'elementary', 'zorin')) + (Get-Distro 'custom' 'C:\isos\x.iso')) {
            $distro.Live | Should -BeNullOrEmpty
            $distro.BootConfigs | Should -Be @('boot/grub/grub.cfg')
            @($distro.BootEdits.Values)[0] | Should -BeLike '* nopersistent'
            $distro.GrubDir | Should -BeNullOrEmpty
            $distro.EspShell | Should -BeNullOrEmpty
        }
    }
    It 'leaves live-boot and the others alone, which make no partition' {
        foreach ($distro in $catalog | Where-Object Kind -in @('debian', 'fedora', 'ultramarine', 'arch', 'cachyos', 'omarchy')) {
            ($distro.BootEdits.Values -join ' ') | Should -Not -BeLike '*nopersistent*'
        }
    }
}

Describe 'Resolve-Download' {
    BeforeAll { $hash = 'a' * 64 }

    It 'picks the newest point release of an Ubuntu flavour' {
        Mock Get-WebText { "$hash *ubuntu-26.04-desktop-amd64.iso`n$hash *ubuntu-26.04.1-desktop-amd64.iso`n$hash *ubuntu-26.04-live-server-amd64.iso`n" }
        $distro = Get-Catalog | Where-Object Id -eq 'ubuntu'
        $download = Resolve-Download $distro
        $download.FileName | Should -Be 'ubuntu-26.04.1-desktop-amd64.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'fails clearly when the ISO is not listed' {
        Mock Get-WebText { "$hash *other.iso`n" }
        { Resolve-Download (Get-Catalog | Where-Object Id -eq 'ubuntu') } | Should -Throw '*Could not find*'
    }
    It 'skips a Mint version that has no ISO yet' {
        Mock Get-WebText { 'href="22.3/" href="23/"' } -ParameterFilter { $Url -like '*/stable/' }
        Mock Get-WebText { throw 'not there' } -ParameterFilter { $Url -like '*/23/*' }
        Mock Get-WebText { "$hash *linuxmint-22.3-cinnamon-64bit.iso`n" } -ParameterFilter { $Url -like '*/22.3/*' }
        (Resolve-Download (Get-Catalog | Where-Object Id -eq 'mint-cinnamon')).FileName | Should -Be 'linuxmint-22.3-cinnamon-64bit.iso'
    }
    It 'reads the elementary link from the site, with no checksum' {
        Mock Get-WebText { '<a href="https://dl.elementaryos.org/release/8.0/elementaryos-8.0-stable-amd64.20250101.iso?token=x">' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'elementary')
        $download.Url | Should -BeLike 'https://dl.elementaryos.org/*'
        $download.Sha256 | Should -BeNullOrEmpty
    }
    It 'picks the newest Zorin OS, counting rereleases, and skips other editions' {
        Mock Get-WebText { 'href="17/" href="18/" href="public/"' } -ParameterFilter { $Url -like '*/zorinos-isos/' }
        Mock Get-WebText {
            "$('1' * 64)  Zorin-OS-18-Core-64-bit-r3.iso`n$('2' * 64)  Zorin-OS-18.1-Core-64-bit.iso`n$('3' * 64)  Zorin-OS-18.1-Core-64-bit-r1.iso`n$('4' * 64)  Zorin-OS-18.1-Education-64-bit-r9.iso`n"
        } -ParameterFilter { $Url -like '*/18/SHA256SUMS.txt' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'zorin')
        $download.Url | Should -Be 'https://mirrors.edge.kernel.org/zorinos-isos/18/Zorin-OS-18.1-Core-64-bit-r1.iso'
        $download.Sha256 | Should -Be ('3' * 64)
    }
    It 'takes the GNOME ISO from Debian''s live checksums, not the files beside it' {
        Mock Get-WebText { "$('1' * 64)  debian-live-13.7.0-amd64-cinnamon.iso`n$('2' * 64)  debian-live-13.7.0-amd64-gnome.iso.contents`n$('3' * 64)  debian-live-13.7.0-amd64-gnome.iso`n" }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'debian')
        $download.FileName | Should -Be 'debian-live-13.7.0-amd64-gnome.iso'
        $download.Sha256 | Should -Be ('3' * 64)
    }
    It 'picks the newest final Fedora Workstation for this kind of PC, not a beta' {
        Mock Invoke-RestMethod {
            , @(
                [pscustomobject]@{ version = '45 Beta'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/beta.iso'; sha256 = 'b'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'aarch64'; variant = 'Workstation'; link = 'https://x/arm.iso'; sha256 = 'c'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'x86_64'; variant = 'KDE'; link = 'https://x/kde.iso'; sha256 = 'd'; size = '1' }
                [pscustomobject]@{ version = '9'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/old.iso'; sha256 = 'e'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/44.iso'; sha256 = 'f'; size = '2851612672' }
            )
        }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'fedora')
        $download.Url | Should -Be 'https://x/44.iso'
        $download.Sha256 | Should -Be 'f'
        $download.Size | Should -Be 2851612672
    }
    It 'skips an Ultramarine version with no ISO yet, and reads its checksum file''s odd path' {
        Mock Get-WebText { 'href="../" href="44/" href="45/"' } -ParameterFilter { $Url -like '*/isos/ultramarine/' }
        Mock Get-WebText { throw 'not there' } -ParameterFilter { $Url -like '*/45/*' }
        Mock Get-WebText { "$hash  artifacts/gnome-gnome-live-anaconda-x86_64-iso/ultramarine-gnome-44-live-anaconda-x86_64.iso`n" } -ParameterFilter { $Url -like '*/44/*' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'ultramarine')
        $download.FileName | Should -Be 'ultramarine-gnome-44-live-anaconda-x86_64.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'resolves KDE independently of Workstation and rejects beta and ARM images' {
        Mock Invoke-RestMethod {
            , @(
                [pscustomobject]@{ version = '45 Beta'; arch = 'x86_64'; variant = 'KDE'; link = 'https://x/beta.iso'; sha256 = 'b'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'aarch64'; variant = 'KDE'; link = 'https://x/arm.iso'; sha256 = 'c'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/gnome.iso'; sha256 = 'd'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'x86_64'; variant = 'KDE'; link = 'https://x/kde.iso'; sha256 = 'a' * 64; size = '3368683520' }
            )
        }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'fedora-kde')
        $download.Url | Should -Be 'https://x/kde.iso'
        $download.Sha256 | Should -Be ('a' * 64)
        $download.Size | Should -Be 3368683520
    }
    It 'picks the newest CachyOS build with a checksum, from the host that works on Windows 10' {
        Mock Get-WebText { '<a href="../">x</a><a href="260628/">a</a> <a href="260809/">b</a> <a href="261001/">c</a>' } -ParameterFilter { $Url -like '*/ISO/desktop/' }
        Mock Get-WebText { throw 'not yet' } -ParameterFilter { $Url -like '*/261001/*' }
        Mock Get-WebText { "$hash  cachyos-desktop-linux-260809.iso`n" } -ParameterFilter { $Url -like '*/260809/*.sha256' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'cachyos')
        $download.Url | Should -Be 'https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'takes Omarchy 4.0 from its site, with its checksum' {
        Mock Get-WebText { '<a href="https://iso.omarchy.org/omarchy-4.0.6.iso">ISO</a> <a href="https://iso.omarchy.org/omarchy-4.0.6.iso.sha256">sum</a>' } -ParameterFilter { $Url -eq 'https://omarchy.org/' }
        Mock Get-WebText { "$hash  omarchy-4.0.6.iso`n" } -ParameterFilter { $Url -like '*.sha256' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'omarchy')
        $download.Url | Should -Be 'https://iso.omarchy.org/omarchy-4.0.6.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'refuses a later Omarchy, which installs in a way usbless has not tried' {
        Mock Get-WebText { '<a href="https://iso.omarchy.org/omarchy-4.5.0.iso">ISO</a>' }
        { Resolve-Download (Get-Catalog | Where-Object Id -eq 'omarchy') } | Should -Throw '*4.5.0*only tried 4.0*'
    }
    It 'takes the dated Arch ISO, whose name is the same on every mirror' {
        Mock Get-WebText { "$hash  archlinux-2026.10.01-x86_64.iso`n$hash  archlinux-x86_64.iso`n$('1' * 64)  archlinux-bootstrap-2026.10.01-x86_64.tar.zst`n" }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'arch')
        $download.Url | Should -Be 'https://geo.mirror.pkgbuild.com/iso/latest/archlinux-2026.10.01-x86_64.iso'
        $download.Sha256 | Should -Be $hash
    }
}

Describe 'Download helpers' {
    It 'explains common curl failures' {
        Get-CurlMessage 6 | Should -BeLike '*internet*'
        Get-CurlMessage 60 | Should -BeLike '*date and time*'
        Get-CurlMessage 23 | Should -BeLike '*free space*'
        Get-CurlMessage 22 | Should -BeLike '*server returned an error*'
        Get-CurlMessage 99 | Should -BeLike '*curl error 99*'
    }
    Context 'when the server refuses to resume' {
        BeforeEach {
            Set-Content -LiteralPath 'TestDrive:\a.iso.part' -Value 'partial'
            Mock Assert-DownloadRoom { }
            Mock Test-CurlAvailable { $true }
            Mock Invoke-WebRequest { throw 'no' }
            Mock Invoke-Curl { 22 }
        }
        It 'keeps the partial file when the server is not answering' {
            { Invoke-Download ([pscustomobject]@{ Url = 'https://x/a.iso'; Size = 100; FileName = 'a.iso' }) 'TestDrive:\a.iso' } | Should -Throw '*server returned an error*'
            'TestDrive:\a.iso.part' | Should -Exist
        }
        It 'starts again when the server is answering' {
            Mock Test-ServerAnswers { $true }
            { Invoke-Download ([pscustomobject]@{ Url = 'https://x/a.iso'; Size = 100; FileName = 'a.iso' }) 'TestDrive:\a.iso' } | Should -Throw
            Should -Invoke Invoke-Curl -Times 2
            $saved = @(Get-ChildItem 'TestDrive:\a.iso.part.saved-*')
            $saved.Count | Should -Be 1
            (Get-Content -LiteralPath $saved[0].FullName -Raw).Trim() | Should -Be 'partial'
        }
    }
    It 'compares versions numerically' {
        (ConvertTo-Version '26') | Should -BeLessThan (ConvertTo-Version '26.04')
        (ConvertTo-Version '9.1') | Should -BeLessThan (ConvertTo-Version '22')
    }
}

Describe 'Preserving download evidence' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Load-Engine.ps1')
        Mock Write-Log { }
    }
    It 'keeps rejected bytes separately without overwriting earlier evidence' {
        $path = Join-Path $TestDrive 'keep.iso'
        Set-Content -LiteralPath $path -Value 'first'
        Preserve-Download $path 'checksum mismatch'
        Set-Content -LiteralPath $path -Value 'second'
        Preserve-Download $path 'different release'
        $files = @(Get-ChildItem "$path.saved-*")
        $files.Count | Should -Be 2
        @($files | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() } | Sort-Object) | Should -Be @('first', 'second')
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'Get-Plan' {
    BeforeAll {
        function New-Space([int64]$TailFree, [int]$UsableGB) {
            [pscustomobject]@{
                Partition = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = [int64]200GB }
                TailFree = $TailFree; UsableGB = $UsableGB
            }
        }
    }
    It 'puts a second partition straight after the installer, and takes its room from what Linux can have' {
        Mock Get-SpaceInfo { New-Space ([int64]100GB) 150 }
        $plan = Get-Plan 60 4 '' 7
        $plan.Shrink | Should -BeFalse
        $plan.LiveOffset | Should -Be ($plan.InstallerOffset + 4GB)
        $plan.LiveSize | Should -Be ([int64]7GB)
        $plan.LiveOffset + $plan.LiveSize | Should -Be $plan.FreeStart
        { Get-Plan 140 4 '' 7 } | Should -Throw
        { Get-Plan 139 4 '' 7 } | Should -Not -Throw
    }
    It 'has no second partition unless asked' {
        Mock Get-SpaceInfo { New-Space ([int64]100GB) 150 }
        (Get-Plan 60 8).LiveSize | Should -Be 0
    }
    It 'leaves C: alone when the free space after it is enough' {
        Mock Get-SpaceInfo { New-Space ([int64]100GB) 150 }
        $plan = Get-Plan 60 8
        $plan.Shrink | Should -BeFalse
        $plan.NewWindowsSize | Should -Be ([int64]200GB)
    }
    It 'shrinks C: by only what the free space cannot cover' {
        Mock Get-SpaceInfo { New-Space ([int64]10GB) 150 }
        $plan = Get-Plan 60 8
        $plan.Shrink | Should -BeTrue
        $plan.NewWindowsSize | Should -Be ([int64]142GB)
    }
    It 'puts Linux last and the installer straight before it, on megabyte boundaries' {
        Mock Get-SpaceInfo { New-Space ([int64]10GB + 123456) 150 }
        $plan = Get-Plan 60 8
        $plan.InstallerOffset % 1MB | Should -Be 0
        $plan.FreeStart % 1MB | Should -Be 0
        $plan.InstallerOffset + 8GB | Should -Be $plan.FreeStart
        $plan.FreeStart + 60GB | Should -Be ([int64]211GB)
    }
    It 'keeps what is left over next to C:' {
        Mock Get-SpaceInfo { New-Space ([int64]100GB) 150 }
        (Get-Plan 60 8).InstallerOffset | Should -Be ([int64]233GB)
    }
    It 'refuses a size that does not fit, and says how much does' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 50 }
        { Get-Plan 60 8 } | Should -Throw '*42 GB or less*'
    }
    It 'refuses when too little is free for any Linux' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 20 }
        { Get-Plan 25 8 } | Should -Throw '*GB more*plenty free*Make room*'
    }
}

Describe 'Get-StuckGB' {
    BeforeAll {
        function New-Space([int64]$TailFree, [int]$UsableGB) { [pscustomobject]@{ TailFree = $TailFree; UsableGB = $UsableGB } }
    }
    It 'finds free space that can not be released, as in issue 4' {
        Get-StuckGB ([int64]239GB) (New-Space ([int64]0) 0) | Should -Be 231
    }
    It 'treats a negative usable size as nothing released' {
        Get-StuckGB ([int64]239GB) (New-Space ([int64]0) -5) | Should -Be 231
    }
    It 'finds nothing stuck when Windows can release it all' {
        Get-StuckGB ([int64]100GB) (New-Space ([int64]0) 92) | Should -Be 0
    }
    It 'does not count free space after C: as released from it' {
        Get-StuckGB ([int64]100GB) (New-Space ([int64]50GB) 50) | Should -Be 92
    }
    It 'finds nothing stuck on a nearly full drive' {
        Get-StuckGB ([int64]2GB) (New-Space ([int64]0) 0) | Should -Be 0
    }
}

Describe 'Make room' {
    BeforeAll {
        $RoomPath = Join-Path $TestDrive 'make-room.json'
        $Logged = @'
A volume shrink analysis was initiated on volume Windows (C:).
 Diagnostic details:
 - The last unmovable file appears to be: \$Extend\$UsnJrnl:$J:$DATA
 - The last cluster of the file is: 0x25716c4
 To find more details please use the "fsutil volume querycluster \\?\Volume{bc7f279c} 0x25716c4" command.
'@
    }
    BeforeEach {
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        Mock Test-HibernationOn { $true }
        Mock Test-EnoughMemoryWithoutPaging { $true }
        Mock Get-PagingSettings { @('?:\pagefile.sys') }
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
    It 'reads the file from the message Windows logs' {
        Get-BlockerFile $Logged | Should -Be '\$Extend\$UsnJrnl:$J:$DATA'
    }
    It 'leaves off the name of the default stream, for showing to people' {
        Get-BlockerFile "The last unmovable file appears to be: \pagefile.sys::`$DATA" | Should -Be '\pagefile.sys'
    }
    It 'sorts blockers by what can be done about them' {
        Get-BlockerKind '\hiberfil.sys' | Should -Be 'hibernation'
        Get-BlockerKind '\pagefile.sys' | Should -Be 'paging'
        Get-BlockerKind '\swapfile.sys' | Should -Be 'paging'
        Get-BlockerKind '\System Volume Information\{a}' | Should -Be 'restore'
        Get-BlockerKind '\$Extend\$UsnJrnl:$J:$DATA' | Should -Be 'journal'
        Get-BlockerKind '\$MFT::$DATA' | Should -Be 'ntfs'
        Get-BlockerKind '\Users\a\b.txt' | Should -Be 'file'
        Get-BlockerKind '' | Should -Be 'unknown'
    }
    It 'saves what it changes before changing it, then restarts' {
        Mock Set-Hibernation { Test-Path $RoomPath | Should -BeTrue }
        Start-MakeRoom
        (Read-RoomState).Phase | Should -Be 'restarting'
        Should -Invoke Set-PagingOff -Times 1
        Should -Invoke Invoke-Shutdown -Times 1
    }
    It 'says the restart is its own before asking Windows for it, so the window lets it through' {
        $Sync.RoomRestarting = $false
        Mock Invoke-Shutdown { $Sync.RoomRestarting | Should -BeTrue }
        Start-MakeRoom
        Should -Invoke Invoke-Shutdown -Times 1
    }
    It 'stops saying so when the restart could not be asked for' {
        Mock Invoke-Shutdown { throw 'no' }
        { Start-MakeRoom } | Should -Throw 'no'
        $Sync.RoomRestarting | Should -BeFalse
    }
    It 'can ask again after a restart was cancelled, with its settings still saved' {
        Start-MakeRoom
        Request-RoomRestart
        Should -Invoke Invoke-Shutdown -Times 2
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 0
        Get-RoomPhase | Should -Be 'continue'
    }
    It 'stops saying so once its settings have gone back' {
        Start-MakeRoom
        Restore-RoomSettings
        $Sync.RoomRestarting | Should -BeFalse
    }
    It 'puts an earlier run on C: back before starting on another drive' {
        Mock Get-PagingSettings { @('?:\pagefile.sys') }
        Start-MakeRoom
        Start-MakeRoom 'Y' | Should -Be 'done'
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 1
        Should -Invoke Restore-Paging -ParameterFilter { ($Saved -join '|') -eq '?:\pagefile.sys' } -Times 1
        $state = Read-RoomState
        $state.Drive | Should -Be 'Y:'
        $state.Hibernation | Should -BeFalse
        $state.PagingOff | Should -BeFalse
    }
    It 'only says it turned back on what it did' {
        $script:logged = @()
        Mock Write-Log { $script:logged += $Message }
        Mock Test-HibernationOn { $false }
        Start-MakeRoom
        Restore-RoomSettings
        ($script:logged -join ' ') | Should -BeLike '*Turned the paging file back on.*'
        ($script:logged -join ' ') | Should -Not -BeLike '*hibernation back on*'
    }
    It 'says nothing was turned back on when another drive changed neither' {
        $script:logged = @()
        Mock Write-Log { $script:logged += $Message }
        Start-MakeRoom 'Y'
        Restore-RoomSettings
        ($script:logged -join ' ') | Should -Not -BeLike '*back on*'
    }
    It 'only takes paging off the system drive' {
        $files = Get-PagingWithoutSystemDrive @("$env:SystemDrive\pagefile.sys 0 0", 'Z:\pagefile.sys 0 0', '?:\pagefile.sys')
        $files | Should -Be @('Z:\pagefile.sys 0 0')
    }
    It 'gets back the exact paging settings it saved' {
        Mock Get-PagingSettings { @('Z:\pagefile.sys 0 0', '?:\pagefile.sys') }
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Restore-Paging -ParameterFilter { ($Saved -join '|') -eq 'Z:\pagefile.sys 0 0|?:\pagefile.sys' } -Times 1
    }
    It 'leaves the paging file on when memory is low' {
        Mock Test-EnoughMemoryWithoutPaging { $false }
        Start-MakeRoom
        Should -Invoke Set-PagingOff -Times 0
    }
    It 'puts everything back if the restart fails' {
        Mock Invoke-Shutdown { throw 'no' }
        { Start-MakeRoom } | Should -Throw 'no'
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 1
        Should -Invoke Restore-Paging -Times 1
        Test-Path $RoomPath | Should -BeFalse
    }
    It 'continues after the restart' {
        Start-MakeRoom
        Get-RoomPhase | Should -Be 'continue'
        Complete-MakeRoom
        Should -Invoke Invoke-Defrag -Times 1
        (Read-RoomState).Phase | Should -Be 'ready'
    }
    It 'puts everything back and lets usbless open when the drive has gone by the restart' {
        Start-MakeRoom
        Mock Invoke-Defrag { throw 'No MSFT_Partition objects found with property DriveLetter equal to E.' }
        Complete-MakeRoom | Should -Be 'failed'
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 1
        Should -Invoke Restore-Paging -Times 1
        Test-Path $RoomPath | Should -BeFalse
        Get-RoomPhase | Should -BeNullOrEmpty
    }
    It 'says so when it finished' {
        Start-MakeRoom
        Complete-MakeRoom | Should -Be 'done'
    }
    It 'restores if the restart never happened' {
        Start-MakeRoom
        Mock Get-LastBoot { [datetime]'2000-01-01' }
        Get-RoomPhase | Should -Be 'restore'
    }
    It 'restores after a crash once it had finished' {
        Start-MakeRoom
        Complete-MakeRoom
        Get-RoomPhase | Should -Be 'restore'
    }
    It 'has nothing to do when it never ran' {
        Get-RoomPhase | Should -BeNullOrEmpty
        Restore-RoomSettings
        Should -Invoke Restore-Paging -Times 0
    }
    It 'only turns hibernation back on if it was on' {
        Mock Test-HibernationOn { $false }
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 0
    }
    It 'keeps the task that puts things back until they are back' {
        Start-MakeRoom
        Complete-MakeRoom
        Should -Invoke Unregister-ResumeTask -Times 1
        Should -Invoke Unregister-RunAfterRestart -Times 0
    }
    It 'finishes restoring when one part fails' {
        Mock Set-Hibernation { if ($On) { throw 'no' } }
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Restore-Paging -Times 1
        Test-Path $RoomPath | Should -BeFalse
    }
}

Describe 'Get-InstallStatus' {
    BeforeAll {
        $installer = [pscustomobject]@{ Partition = $null; Label = 'USBLINSTALL'; Letter = 'H' }
    }
    BeforeEach {
        Mock Read-State { $null }
        Mock Get-UsblessPartitions { }
        Mock Get-FirmwareEntries { }
        Mock Get-BcdEntries { }
        Mock Test-LinuxInstalled { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*BOOTX64.EFI' }
    }
    It 'is none on a clean PC' {
        Get-InstallStatus | Should -Be 'none'
    }
    It 'is ready once the copy has finished, even with no startup entry' {
        Mock Read-State { [pscustomobject]@{ Copied = $true; BootNumber = $null } }
        Mock Get-UsblessPartitions { $installer }
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'keeps an owned setup with the older state schema ready' {
        Mock Read-State { [pscustomobject]@{ BootNumber = 5 } }
        Mock Get-UsblessPartitions { [pscustomobject]@{ Partition = $null; Label = 'USBLINSTALL'; Letter = 'H' } }
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'gets the drive letter back instead of calling it a failed attempt' {
        Mock Read-State { [pscustomobject]@{ Copied = $true } }
        Mock Get-UsblessPartitions { [pscustomobject]@{ Partition = $null; Label = 'USBLINSTALL'; Letter = $null } }
        Mock Get-DriveLetter { 'H' }
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'is installed when a new Linux boot loader appeared' {
        Mock Read-State { [pscustomobject]@{ Copied = $true } }
        Mock Get-UsblessPartitions { $installer }
        Mock Test-LinuxInstalled { $true }
        Get-InstallStatus | Should -Be 'installed'
    }
    It 'is leftover when the copy never finished' {
        Mock Read-State { [pscustomobject]@{ Copied = $false; BootNumber = $null } }
        Mock Get-UsblessPartitions { $installer }
        Get-InstallStatus | Should -Be 'leftover'
    }
    It 'is leftover when only a startup entry remains' {
        Mock Get-FirmwareEntries { 7 }
        Get-InstallStatus | Should -Be 'leftover'
    }
}

Describe 'Test-LinuxInstalled' {
    BeforeEach { Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } } }
    It 'does not guess for a setup made before this was recorded' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\ubuntu\shimx64.efi' } }
        Test-LinuxInstalled ([pscustomobject]@{ Copied = $true }) | Should -BeFalse
    }
    It 'ignores a boot loader that was already there' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\pond\shimx64.efi' } }
        Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @('\EFI\pond\shimx64.efi') }) | Should -BeFalse
    }
    It 'notices a new one' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\ubuntu\shimx64.efi' } }
        Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @() }) | Should -BeTrue
    }
    Context 'when the firmware has dropped the startup entry' {
        BeforeEach {
            Mock Get-LinuxLoaders { }
            Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
            Mock Get-Partition { }
            Mock Get-LinuxPartitions { [pscustomobject]@{ Guid = '{new}' } }
        }
        It 'notices a new Linux partition' {
            Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @(); LinuxBefore = @('{old}') }) | Should -BeTrue
        }
        It 'ignores a partition that was already there' {
            Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @(); LinuxBefore = @('{new}') }) | Should -BeFalse
        }
        It 'does not guess for a setup made before partitions were recorded' {
            Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @() }) | Should -BeFalse
        }
    }
}

Describe 'Get-CasperPartition' {
    BeforeAll {
        # The layout seen in QEMU: 512-byte sectors, and casper starting at sector 16986112.
        $sector = 512
        function New-Disk {
            @(
                [pscustomobject]@{ DiskNumber = 0; Offset = [int64]2048 * $sector; Size = [int64]204800 * $sector; GptType = $EspType; Guid = '{esp}'; PartitionNumber = 1 }
                [pscustomobject]@{ DiskNumber = 0; Offset = [int64]206848 * $sector; Size = [int64]2097152 * $sector; GptType = $BasicDataType; Guid = '{c}'; PartitionNumber = 2 }
                [pscustomobject]@{ DiskNumber = 0; Offset = [int64]2304000 * $sector; Size = [int64]14680064 * $sector; GptType = $BasicDataType; Guid = '{usbless}'; PartitionNumber = 3 }
                [pscustomobject]@{ DiskNumber = 0; Offset = [int64]16986112 * $sector; Size = [int64]150784000 * $sector; GptType = $LinuxPartitionTypes[0]; Guid = '{casper}'; PartitionNumber = 4 }
            )
        }
        function New-State {
            [pscustomobject]@{
                RestartedAt = '2026-10-31T10:00:00'; LinuxBefore = @(); LoadersBefore = @()
                Partitions = @([pscustomobject]@{ Role = 'installer'; Offset = [int64]2304000 * $sector; Size = [int64]14680064 * $sector })
            }
        }
    }
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ Number = 0; LogicalSectorSize = 512 } }
        Mock Test-CasperContents { $true }
        Mock Get-LinuxLoaders { }
    }
    It 'finds what casper made' {
        (Get-CasperPartition (New-State) (New-Disk)).Guid | Should -Be '{casper}'
    }
    It 'finds it after a recovery partition too' {
        $disk = New-Disk
        $disk[3].Offset = [int64]163577856 * $sector
        $recovery = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]161478656 * $sector; Size = [int64]2099167 * $sector; GptType = $RecoveryType; Guid = '{re}'; PartitionNumber = 5 }
        (Get-CasperPartition (New-State) @($disk + $recovery)).Guid | Should -Be '{casper}'
    }
    It 'is not fooled by <why>' -ForEach @(
        @{ why = 'a state file from before the restart'; state = { $s = New-State; $s.RestartedAt = $null; $s }; disk = { New-Disk } }
        @{ why = 'a setup that did not record what was there'; state = { [pscustomobject]@{ RestartedAt = 'x'; Partitions = (New-State).Partitions } }; disk = { New-Disk } }
        @{ why = 'a partition that was there before usbless'; state = { $s = New-State; $s.LinuxBefore = @('{casper}'); $s }; disk = { New-Disk } }
        @{ why = 'a partition before the installer'; state = { $s = New-State; $s.Partitions[0].Offset = [int64]166000000 * 512; $s }; disk = { New-Disk } }
        @{ why = 'a partition of another type'; state = { New-State }; disk = { $d = New-Disk; $d[3].GptType = $BasicDataType; $d } }
        @{ why = 'a partition not where casper starts one'; state = { New-State }; disk = { $d = New-Disk; $d[3].Offset = [int64]16984064 * 512; $d } }
        @{ why = 'a partition with another after it'; state = { New-State }; disk = { @(New-Disk) + [pscustomobject]@{ DiskNumber = 0; Offset = [int64]167700000 * 512; Size = 1MB; GptType = $BasicDataType; Guid = '{after}'; PartitionNumber = 5 } } }
    ) {
        Get-CasperPartition (& $state) (& $disk) | Should -BeNullOrEmpty
    }
    It 'leaves a partition holding something else' {
        Mock Test-CasperContents { $false }
        Get-CasperPartition (New-State) (New-Disk) | Should -BeNullOrEmpty
    }
    It 'leaves a partition on another disk' {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 1 } }
        Get-CasperPartition (New-State) (New-Disk) | Should -BeNullOrEmpty
    }
    It 'does not make usbless say Linux is installed' {
        Mock Get-Partition { New-Disk }
        Mock Get-LinuxPartitions { (New-Disk)[3] }
        Test-LinuxInstalled (New-State) | Should -BeFalse
    }
    It 'still says Linux is installed if another Linux partition is there' {
        Mock Get-Partition { New-Disk }
        Mock Test-CasperContents { $false }
        Mock Get-LinuxPartitions { (New-Disk)[3] }
        Test-LinuxInstalled (New-State) | Should -BeTrue
    }
    It 'still says Linux is installed when a new boot loader says so' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\ubuntu\shimx64.efi' } }
        Test-LinuxInstalled (New-State) | Should -BeTrue
    }
    It 'removes it, and nothing else' {
        Mock Get-Partition { New-Disk }
        Mock Remove-PartitionAt { }
        Remove-CasperPartition (New-State)
        Should -Invoke Remove-PartitionAt -Times 1 -Exactly -ParameterFilter { $Offset -eq [int64]16986112 * 512 }
    }
    It 'removes nothing it cannot tie to this setup' {
        Mock Get-Partition { New-Disk }
        Mock Test-CasperContents { $false }
        Mock Remove-PartitionAt { }
        Remove-CasperPartition (New-State)
        Should -Invoke Remove-PartitionAt -Times 0 -Exactly
    }
}

Describe 'Test-CasperContents' {
    BeforeAll {
        function New-ExtHead([string]$Label) {
            $head = New-Object byte[] (128KB)
            [BitConverter]::GetBytes([uint32]1000).CopyTo($head, 1024)
            $head[1080] = 0x53; $head[1081] = 0xEF
            [Text.Encoding]::ASCII.GetBytes($Label).CopyTo($head, 1144)
            , $head
        }
    }
    It 'reads the name of an ext file system, and only of one' {
        [Usbless.DiskProbe]::ExtLabel((New-ExtHead 'writable')) | Should -BeExactly 'writable'
        [Usbless.DiskProbe]::ExtLabel((New-Object byte[] (128KB))) | Should -BeNullOrEmpty
    }
    It 'knows an empty partition from one with anything on it' {
        [Usbless.DiskProbe]::IsBlank((New-Object byte[] (128KB))) | Should -BeTrue
        [Usbless.DiskProbe]::IsBlank((New-ExtHead 'writable')) | Should -BeFalse
    }
}

Describe 'Test-LinuxSignature' {
    It 'never picks a system or boot partition' {
        Test-LinuxSignature ([pscustomobject]@{ IsSystem = $true; IsBoot = $false; DiskNumber = 0; Offset = 0 }) | Should -BeFalse
        Test-LinuxSignature ([pscustomobject]@{ IsSystem = $false; IsBoot = $true; DiskNumber = 0; Offset = 0 }) | Should -BeFalse
    }
}

Describe 'Get-IsoKernelPath' {
    BeforeEach {
        $iso = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$iso\boot\grub" | Out-Null
    }
    It 'skips a memory tester listed first' {
        Set-Content "$iso\boot\grub\grub.cfg" "menuentry 'a' {`n  linux /boot/memtest.efi`n}`nmenuentry 'b' {`n  linux /casper/vmlinuz quiet`n}"
        Get-IsoKernelPath $iso | Should -Be "$iso\casper\vmlinuz"
    }
    It 'says nothing without a menu' {
        Get-IsoKernelPath (Join-Path $TestDrive 'none') | Should -BeNullOrEmpty
    }
    It 'reads Fedora''s menu, which is elsewhere and writes ($root) before its paths' {
        New-Item -ItemType Directory -Path "$iso\boot\grub2" -Force | Out-Null
        Remove-Item "$iso\boot\grub" -Recurse
        Set-Content "$iso\boot\grub2\grub.cfg" "menuentry 'a' {`n`tlinux (`$root)/boot/x86_64/loader/linux quiet`n}"
        Get-IsoKernelPath $iso | Should -Be "$iso\boot\x86_64\loader\linux"
    }
}

Describe 'Boot config' {
    BeforeAll {
        function Get-CatalogEntry([string]$Id) { Get-Catalog | Where-Object Id -eq $Id }
        function Get-Edited([string]$Id, [string]$Text) { Get-EditedBootConfig (Get-CatalogEntry $Id) $Text }
    }
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$root\boot\grub2", "$root\boot\grub", "$root\loader\entries" -Force | Out-Null
    }
    It 'points Fedora at the installer partition, as in Fedora 44''s menu' {
        $text = Get-Edited 'fedora' "search --file --set=root /boot/0xf20784ad`n`tlinux (`$root)/boot/x86_64/loader/linux quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image rd.live.check`n"
        $text | Should -BeLike "*root=live:LABEL=$InstallerLabel *rd.live.image*"
        $text | Should -BeLike "search --no-floppy --label --set=root $InstallerLabel*"
        $text | Should -Not -BeLike '*CDLABEL*'
        $text | Should -Not -BeLike '*rd.live.check*'
    }
    It 'points Ultramarine at the installer partition, as in Ultramarine 44''s menu' {
        $text = Get-Edited 'ultramarine' "search --no-floppy --set=root --label 'UM-Gn-Live-Anaconda'`n`tlinux /boot/vmlinuz root=live:CDLABEL=UM-Gn-Live-Anaconda rd.live.image rd.live.check enforcing=0 quiet rhgb`n"
        $text | Should -BeLike "*root=live:LABEL=$InstallerLabel *rd.live.image enforcing=0 quiet rhgb*"
        $text | Should -BeLike "search --no-floppy --label --set=root $InstallerLabel*"
        $text | Should -Not -BeLike '*UM-Gn*'
    }
    It 'frees the installer''s drive for Anaconda without losing the desktop, as tested in Fedora 44' {
        foreach ($id in 'fedora', 'ultramarine') {
            $text = Get-Edited $id 'linux /x root=live:CDLABEL=X rd.live.image'
            # Quoted for GRUB, so that it stays one argument. Each of the others stops systemd.run replacing the normal start.
            $text | Should -BeLike '*"systemd.run=/usr/bin/umount -l /run/initramfs/live" *'
            foreach ($needed in 'systemd.run_success_action=none', 'systemd.run_failure_action=none', 'systemd.unit=graphical.target', 'systemd.wants=kernel-command-line.service') {
                $text | Should -BeLike "* $needed *"
            }
        }
    }
    It 'points Omarchy at its second partition and frees its disk, the same however often it runs' {
        $omarchy = Get-CatalogEntry 'omarchy'
        $text = Get-EditedBootConfig $omarchy 'linux /arch/boot/x86_64/vmlinuz-linux-t2 archisobasedir=arch archisosearchuuid=2026-10-19-22-18-53-00 quiet splash'
        $text | Should -BeLike "linux /arch/boot/x86_64/vmlinuz-linux-t2 archisobasedir=arch archisolabel=$LiveLabel `"systemd.run=umount -l /run/archiso/bootmnt`" *systemd.unit=multi-user.target* quiet splash"
        Get-EditedBootConfig $omarchy $text | Should -BeExactly $text
    }
    It 'points CachyOS and Arch at the installer partition, and keeps their other settings' {
        Get-Edited 'cachyos' 'linux /arch/boot/x86_64/vmlinuz-linux-cachyos archisobasedir=arch archisosearchuuid=2026-08-09-15-47-03-00 cow_spacesize=10G' |
            Should -Be "linux /arch/boot/x86_64/vmlinuz-linux-cachyos archisobasedir=arch archisolabel=$InstallerLabel cow_spacesize=10G"
        Get-Edited 'arch' 'options  archisobasedir=arch archisosearchuuid=2026-10-01-14-49-03-00 ' |
            Should -Be "options  archisobasedir=arch archisolabel=$InstallerLabel "
    }
    It 'changes every Arch boot entry, and leaves the memory tester alone' {
        Set-Content "$root\loader\entries\01-archiso-linux.conf" 'options  archisobasedir=arch archisosearchuuid=2026 '
        Set-Content "$root\loader\entries\02-archiso-speech-linux.conf" 'options  archisobasedir=arch archisosearchuuid=2026 accessibility=on'
        Set-Content "$root\loader\entries\03-archiso-memtest86+x64.conf" 'efi /boot/memtest86+/memtest.efi'
        Update-BootConfig (Get-CatalogEntry 'arch') $root
        Get-Content "$root\loader\entries\01-archiso-linux.conf" | Should -BeLike "*archisolabel=$InstallerLabel*"
        Get-Content "$root\loader\entries\02-archiso-speech-linux.conf" | Should -BeLike "*archisolabel=$InstallerLabel accessibility=on"
        Get-Content "$root\loader\entries\03-archiso-memtest86+x64.conf" | Should -Be 'efi /boot/memtest86+/memtest.efi'
    }
    It 'keeps every other byte, adds no byte order mark and copes with a read-only copy' {
        $path = "$root\boot\grub2\grub.cfg"
        # A menu title in UTF-8, and Unix line endings GRUB relies on.
        $before = [Text.Encoding]::UTF8.GetBytes("menuentry 'Dévelop' {`n`troot=live:CDLABEL=X quiet`n}`n")
        [IO.File]::WriteAllBytes($path, $before)
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        Update-BootConfig (Get-CatalogEntry 'fedora') $root
        $edited = (Get-CatalogEntry 'fedora').BootEdits['root=live:CDLABEL=\S+']
        $expected = [Text.Encoding]::UTF8.GetBytes("menuentry 'Dévelop' {`n`t$edited quiet`n}`n")
        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($expected -join ',')
    }
    It 'tells casper not to take the space, before anything the installed system would copy' -ForEach @(
        @{ id = 'ubuntu'; line = '    linux  /casper/vmlinuz  --- quiet splash'; want = '    linux  /casper/vmlinuz nopersistent  --- quiet splash' }
        @{ id = 'zorin'; line = "`tlinux /casper/vmlinuz maybe-ubiquity quiet splash ---"; want = "`tlinux /casper/vmlinuz nopersistent maybe-ubiquity quiet splash ---" }
        @{ id = 'mint-cinnamon'; line = "`tlinux`t/casper/vmlinuz  boot=casper uuid=6e72f523 username=mint"; want = "`tlinux`t/casper/vmlinuz nopersistent  boot=casper uuid=6e72f523 username=mint" }
        @{ id = 'elementary'; line = ' linux /casper/vmlinuz boot=casper maybe-ubiquity quiet splash'; want = ' linux /casper/vmlinuz nopersistent boot=casper maybe-ubiquity quiet splash' }
        @{ id = 'pop'; line = "`tlinux /casper_pop-os_24.04_amd64/vmlinuz.efi boot=casper live-media-path=/casper_pop-os_24.04_amd64"; want = "`tlinux /casper_pop-os_24.04_amd64/vmlinuz.efi nopersistent boot=casper live-media-path=/casper_pop-os_24.04_amd64" }
    ) {
        Get-Edited $id $line | Should -Be $want
    }
    It 'changes every entry but the memory tester, and changes nothing else' {
        $path = "$root\boot\grub\grub.cfg"
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("menuentry 'Try' {`n linux /casper/vmlinuz --- quiet`n}`nmenuentry 'Safe' {`n linux /casper/vmlinuz nomodeset --- quiet`n}`nmenuentry 'Test' {`n linux /boot/memtest.efi`n}`n"))
        Update-BootConfig (Get-CatalogEntry 'ubuntu') $root
        [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path)) |
            Should -Be "menuentry 'Try' {`n linux /casper/vmlinuz nopersistent --- quiet`n}`nmenuentry 'Safe' {`n linux /casper/vmlinuz nopersistent nomodeset --- quiet`n}`nmenuentry 'Test' {`n linux /boot/memtest.efi`n}`n"
    }
    It 'does nothing the second time, even with the copy to memory there' {
        $path = "$root\boot\grub\grub.cfg"
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("linux /casper/vmlinuz toram nopersistent --- quiet`n"))
        $before = [IO.File]::ReadAllBytes($path)
        Update-BootConfig (Get-CatalogEntry 'ubuntu') $root
        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($before -join ',')
    }
    It 'copes with both changes together when replacing Windows' {
        $distro = Get-CatalogEntry 'ubuntu'
        Get-EditedBootConfig $distro 'linux /casper/vmlinuz --- quiet' -FullDisk | Should -Be 'linux /casper/vmlinuz toram nopersistent --- quiet'
    }
    It 'knows a menu it can edit, and says so when a new release changes it' {
        $fedora = Get-CatalogEntry 'fedora'
        Test-BootConfigKnown $fedora $root | Should -BeFalse
        Set-Content "$root\boot\grub2\grub.cfg" 'linux /x root=UUID=abc'
        Test-BootConfigKnown $fedora $root | Should -BeFalse
        Set-Content "$root\boot\grub2\grub.cfg" 'linux /x root=live:CDLABEL=abc'
        Test-BootConfigKnown $fedora $root | Should -BeTrue
    }
    It 'needs a casper line in Ubuntu''s menu, and accepts one' {
        $ubuntu = Get-CatalogEntry 'ubuntu'
        Test-BootConfigKnown $ubuntu $root | Should -BeFalse
        Set-Content "$root\boot\grub\grub.cfg" 'linux /boot/memtest.efi'
        Test-BootConfigKnown $ubuntu $root | Should -BeFalse
        Set-Content "$root\boot\grub\grub.cfg" 'linux /casper/vmlinuz --- quiet'
        Test-BootConfigKnown $ubuntu $root | Should -BeTrue
    }
}

Describe 'Copy-EspLoader' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $source = "$root\EFI\BOOT"
        $folder = "$root\esp\EFI\usbless"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content "$source\BOOTx64.EFI" 'shim'
        Set-Content "$source\grubx64.efi" 'grub'
        Set-Content "$source\grub.cfg" 'from the iso'
    }
    It 'writes Ubuntu''s files exactly as builds before this one did' {
        Copy-EspLoader (Get-Catalog | Where-Object Id -eq 'ubuntu') $source $folder
        @(Get-ChildItem $folder | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('BOOTx64.EFI', 'grub.cfg', 'grubx64.efi')
        [IO.File]::ReadAllText("$folder\grub.cfg") | Should -BeExactly "search --no-floppy --file --set=root /.disk/info`r`nset prefix=(`$root)/boot/grub`r`nconfigfile `$prefix/grub.cfg`r`n"
    }
    It 'writes the same for a chosen ISO, Zorin OS and Debian, which have /.disk/info' {
        foreach ($distro in (Get-Distro 'custom' 'a.iso'), (Get-Catalog | Where-Object Id -eq 'zorin'), (Get-Catalog | Where-Object Id -eq 'debian')) {
            (Get-EspGrubConfig $distro) -join '|' | Should -BeExactly 'search --no-floppy --file --set=root /.disk/info|set prefix=($root)/boot/grub|configfile $prefix/grub.cfg'
        }
    }
    It 'finds the installer by label for systems without /.disk/info' {
        foreach ($case in @(@('fedora', 'boot/grub2'), @('ultramarine', 'boot/grub'), @('cachyos', 'boot/grub'))) {
            (Get-EspGrubConfig (Get-Catalog | Where-Object Id -eq $case[0])) -join '|' |
                Should -BeExactly "search --no-floppy --label --set=root $InstallerLabel|set prefix=(`$root)/$($case[1])|configfile `$prefix/grub.cfg"
        }
    }
    It 'starts Arch through the ISO''s EFI Shell, because systemd-boot cannot leave its partition' {
        $arch = Get-Catalog | Where-Object Id -eq 'arch'
        Set-Content "$root\shellx64.efi" 'shell'
        Copy-EspLoader $arch $source $folder
        (Get-Content "$folder\BOOTX64.EFI") | Should -Be 'shell'
        "$folder\grub.cfg" | Should -Not -Exist
        "$folder\grubx64.efi" | Should -Not -Exist
        $script = (Get-Content "$folder\startup.nsh") -join "`n"
        $script | Should -BeLike '*if exist fs%a:\arch\x86_64\airootfs.sfs then*'
        $script | Should -BeLike '*\EFI\BOOT\BOOTx64.EFI*'
    }
}

Describe 'Read-Iso' {
    BeforeAll {
        function New-IsoFiles([hashtable]$Files) {
            foreach ($name in $Files.Keys) {
                $path = Join-Path $isoRoot $name
                New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $Files[$name]
            }
        }
    }
    BeforeEach {
        $isoRoot = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $isoRoot | Out-Null
        New-PSDrive -Name USBLISO -PSProvider FileSystem -Root $isoRoot -Scope Global | Out-Null
        Mock Mount-Iso { 'USBLISO' }
        Mock Get-SecureBootProblem { }
        Mock Set-Status { }
    }
    AfterEach { Remove-PSDrive -Name USBLISO -Scope Global }
    It 'still wants casper and /.disk/info for a chosen ISO' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'LiveOS\squashfs.img' = 'x' }
        { Read-Iso 'a.iso' (Get-Distro 'custom' 'a.iso') } | Should -Throw '*Ubuntu-style*'
    }
    It 'accepts Fedora, whose ISO has neither' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'LiveOS\squashfs.img' = 'x'; 'boot\grub2\grub.cfg' = 'linux ($root)/boot/x root=live:CDLABEL=a'; 'boot\x' = 'x' }
        (Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'fedora')).Letter | Should -Be 'USBLISO'
    }
    It 'refuses the wrong file for the system picked' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'boot\grub2\grub.cfg' = 'root=live:CDLABEL=a' }
        { Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'fedora') } | Should -Throw "*doesn't look like Fedora*"
    }
    Context 'Omarchy' {
        BeforeEach {
            $omarchy = Get-Catalog | Where-Object Id -eq 'omarchy'
            $menu = 'linux /arch/boot/x86_64/vmlinuz-linux-t2 archisobasedir=arch archisosearchuuid=2026-10-19-22-18-53-00 quiet'
        }
        It 'keeps its live image apart from what goes on FAT32' {
            New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'arch\x86_64\airootfs.sfs' = 'x' * 1000; 'arch\x86_64\airootfs.sha512' = 'x'; 'arch\boot\x86_64\vmlinuz-linux-t2' = 'x'; 'boot\grub\grub.cfg' = $menu }
            $iso = Read-Iso 'a.iso' $omarchy
            @($iso.LiveFiles.Name | Sort-Object) | Should -Be @('airootfs.sfs', 'airootfs.sha512')
            $iso.LiveBytes | Should -BeGreaterThan 1000
            $iso.Bytes | Should -BeLessThan 1000
            $iso.LiveGB | Should -Be 1
            $iso.InstallerGB | Should -Be 4
        }
        It 'refuses an ISO with the separate image later versions install from, before the disk changes' {
            New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'arch\x86_64\airootfs.sfs' = 'x'; 'arch\x86_64\omarchy-root.img.zst' = 'x'; 'boot\grub\grub.cfg' = $menu }
            { Read-Iso 'a.iso' $omarchy } | Should -Throw "*hasn't tried*Nothing has been changed*"
        }
    }
    It 'has no second partition for anything else' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'arch\x86_64\airootfs.sfs' = 'x'; 'k' = 'x'; 'boot\grub\grub.cfg' = 'linux /k archisobasedir=arch archisosearchuuid=2026' }
        $iso = Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'cachyos')
        $iso.LiveGB | Should -Be 0
        $iso.Bytes | Should -BeGreaterThan 0
    }
    It 'refuses a release that starts in a way usbless cannot edit, before the disk changes' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'arch\x86_64\airootfs.sfs' = 'x'; 'boot\grub\grub.cfg' = 'linux /k archisodevice=/dev/x' }
        { Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'cachyos') } | Should -Throw "*doesn't know yet*Nothing has been changed*"
    }
}

Describe 'The window''s figure for the installer' {
    It 'matches Read-Iso for an ISO of <gb> GB' -ForEach @(
        @{ gb = 1; expected = 4 }, @{ gb = 3.5; expected = 4 }, @{ gb = 6; expected = 7 }, @{ gb = 6.5; expected = 7 }, @{ gb = 12; expected = 13 }
    ) {
        [Usbless.Engine]::InstallerGBFor([int64]($gb * 1GB)) | Should -Be $expected
        [int][math]::Max([double]4, [math]::Ceiling(([int64]($gb * 1GB) + 512MB) / 1GB)) | Should -Be $expected
    }
}

Describe 'Get-StateDistro' {
    It 'finds the system an install was for' {
        (Get-StateDistro ([pscustomobject]@{ DistroId = 'fedora'; Distro = 'Fedora Workstation' })).GrubDir | Should -Be 'boot/grub2'
    }
    It 'treats one no longer in the catalog as a chosen ISO, which starts as Ubuntu does' {
        $distro = Get-StateDistro ([pscustomobject]@{ DistroId = 'gone'; Distro = 'Gone' })
        $distro.Name | Should -Be 'Gone'
        $distro.GrubDir | Should -BeNullOrEmpty
    }
}

Describe 'Repair-ShortenedNames' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$root\dists\noble\main\binary-amd64", "$root\pool\main" | Out-Null
        $long = 'system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd64.deb'
    }
    It 'gives a shortened package its real name back' {
        Set-Content "$root\dists\noble\main\binary-amd64\Packages" "Package: a`nFilename: ./pool/main/$long`n"
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$long" | Should -Exist
    }
    It 'reads a compressed index' {
        $file = [IO.File]::Create("$root\dists\noble\main\binary-amd64\Packages.gz")
        $zip = New-Object IO.Compression.GZipStream($file, [IO.Compression.CompressionMode]::Compress)
        $bytes = [Text.Encoding]::ASCII.GetBytes("Filename: pool/main/$long`n")
        $zip.Write($bytes, 0, $bytes.Length)
        $zip.Dispose()
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$long" | Should -Exist
    }
    It 'never renames a file the index also lists' {
        $short = 'system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb'
        Set-Content "$root\dists\noble\main\binary-amd64\Packages" "Filename: pool/main/$long`nFilename: pool/main/$short`n"
        Set-Content "$root\pool\main\$short" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$short" | Should -Exist
        "$root\pool\main\$long" | Should -Not -Exist
    }
    It 'does not guess between two candidates' {
        Set-Content "$root\dists\noble\main\binary-amd64\Packages" "Filename: pool/main/$long`n"
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb" 'x'
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_a.deb" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$long" | Should -Not -Exist
    }
    It 'copes with an ISO that has no package indexes' {
        { Repair-ShortenedNames (Join-Path $TestDrive 'empty') } | Should -Not -Throw
    }
}

Describe 'Get-RecordedPartitions' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; Offset = [int64]500GB; Size = [int64]8GB; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 5; Offset = [int64]400GB; Size = [int64]60GB; IsSystem = $false; IsBoot = $false }
        }
        Mock Read-PartitionHead { New-Object byte[] 16 }
        Mock Get-Volume { $null }
    }
    It 'finds a recorded partition that was never formatted' {
        $state = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'installer'; Offset = [int64]500GB; Size = [int64]8GB }) }
        @(Get-RecordedPartitions $state @('installer')).PartitionNumber | Should -Be 4
    }
    It 'only looks at the roles asked for' {
        $state = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'root'; Offset = [int64]400GB; Size = [int64]60GB }) }
        @(Get-RecordedPartitions $state @('installer')).Count | Should -Be 0
    }
    It 'leaves it alone once Linux has been installed there' {
        Mock Read-PartitionHead { [byte[]](0, 1, 0) }
        $state = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'root'; Offset = [int64]400GB; Size = [int64]60GB }) }
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 0
    }
    It 'copes with no state' {
        @(Get-RecordedPartitions $null @('installer')).Count | Should -Be 0
    }
}

Describe 'Firmware' {
    It 'can tell how this PC started' {
        [Usbless.Firmware]::IsUefi() | Should -BeOfType [bool]
    }
}

Describe 'Get-StartupInfo' {
    BeforeEach {
        Mock Test-System { throw 'blocked' }
        Mock Read-State { $null }
        Mock Test-CameBack { $false }
        Mock Test-SecureBoot { $false }
        Mock Get-BootMenuKey { 'F12' }
        Mock Get-OtherSystem { $null }
        Mock Get-SpaceInfo { [pscustomobject]@{ UsableGB = 100; TailFree = 0; Partition = [pscustomobject]@{ DiskNumber = 0; Size = [int64]200GB } } }
        Mock Get-Volume { [pscustomobject]@{ Size = [int64]200GB; SizeRemaining = [int64]100GB } }
        Mock Get-Disk { [pscustomobject]@{ FriendlyName = 'Disk' } }
        Mock Get-DriveTargets { }
        Mock Get-DownloadDrives { }
    }
    It 'stops a new install on a PC with a blocker' {
        Mock Get-InstallStatus { 'none' }
        { Get-StartupInfo } | Should -Throw 'blocked'
    }
    It 'still lets someone undo on that PC' {
        Mock Get-InstallStatus { 'leftover' }
        (Get-StartupInfo).Status | Should -Be 'leftover'
    }
    It 'says which drive a setup took its space from, for Undo to report on' {
        Mock Get-InstallStatus { 'ready' }
        Mock Get-StateDisk { 0 }
        Mock Read-State { [pscustomobject]@{ TargetOffset = [int64]1GB; TargetLetter = 'D' } }
        (Get-StartupInfo).StateLetter | Should -Be 'D'
    }
    It 'takes a setup from before that was recorded to mean C:' {
        Mock Get-InstallStatus { 'ready' }
        Mock Get-StateDisk { 0 }
        Mock Read-State { [pscustomobject]@{ Copied = $true } }
        (Get-StartupInfo).StateLetter | Should -Be $env:SystemDrive.TrimEnd(':')
    }
}

Describe 'Get-WindowsEsp' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 1 } }
        Mock Get-Partition {
            [pscustomobject]@{ Guid = '{other}'; DiskNumber = 1; GptType = $EspType; IsSystem = $false }
            [pscustomobject]@{ Guid = '{first}'; DiskNumber = 0; GptType = $EspType; IsSystem = $true }
            [pscustomobject]@{ Guid = '{data}'; DiskNumber = 1; GptType = $BasicDataType; IsSystem = $false }
        }
    }
    It 'finds the one Windows starts from, even on another disk' {
        (Get-WindowsEsp).Guid | Should -Be '{first}'
    }
    It 'takes the one Use-Esp opens over the lowest Windows Boot Manager entry, when there are two' {
        Mock Get-BootEntries {
            [pscustomobject]@{ Number = 0; Path = '\EFI\Microsoft\Boot\bootmgfw.efi'; PartitionGuid = '{other}' }
            [pscustomobject]@{ Number = 1; Path = '\EFI\Microsoft\Boot\bootmgfw.efi'; PartitionGuid = '{first}' }
        }
        (Get-WindowsEsp).Guid | Should -Be '{first}'
    }
    It 'goes by the startup entry when Windows does not say which it started from' {
        Mock Get-Partition {
            [pscustomobject]@{ Guid = '{other}'; DiskNumber = 1; GptType = $EspType; IsSystem = $false }
            [pscustomobject]@{ Guid = '{first}'; DiskNumber = 0; GptType = $EspType; IsSystem = $false }
        }
        Mock Get-BootEntries { [pscustomobject]@{ Number = 0; Path = '\EFI\Microsoft\Boot\bootmgfw.efi'; PartitionGuid = '{first}' } }
        (Get-WindowsEsp).Guid | Should -Be '{first}'
    }
    It 'falls back to the Windows disk' {
        Mock Get-BootEntries { }
        Mock Get-Partition { [pscustomobject]@{ Guid = '{other}'; DiskNumber = 1; GptType = $EspType; IsSystem = $false } }
        (Get-WindowsEsp).Guid | Should -Be '{other}'
    }
    It 'says so when there is none' {
        Mock Get-Partition { }
        { Get-WindowsEsp } | Should -Throw '*EFI system partition*'
    }
}

Describe 'Invoke-Cleanup' {
    BeforeEach {
        $script:removed = @()
        $state = [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; FastStartupWasOn = $false; BitLockerPaused = $false }
        Mock Read-State { $state }
        Mock Get-BcdEntries { }
        Mock Get-FirmwareEntries { }
        Mock Use-Esp { }
        Mock Get-RecordedPartitions { }
        Mock Remove-PartitionAt { $script:removed += $Offset }
        Mock Get-UsblessPartitions {
            [pscustomobject]@{ Label = 'USBLBOOT'; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]100GB } }
            [pscustomobject]@{ Label = 'USBLINSTALL'; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]160GB } }
        }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Size = [int64]100GB } }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]100GB } }
    }
    It 'removes the second installer partition too, with Linux staying or not' {
        Mock Get-UsblessPartitions {
            [pscustomobject]@{ Label = 'USBLINSTALL'; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]160GB } }
            [pscustomobject]@{ Label = $LiveLabel; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]164GB } }
        }
        Mock Test-LinuxInstalled { $true }
        Invoke-Cleanup
        $script:removed | Should -Be @([int64]160GB, [int64]164GB)
    }
    It 'removes every partition usbless made when Linux is not installed' {
        Mock Test-LinuxInstalled { $false }
        Invoke-Cleanup
        $script:removed | Should -Be @([int64]100GB, [int64]160GB)
    }
    It 'gives space back to C: when usbless shrank it' {
        Mock Test-LinuxInstalled { $false }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]160GB } }
        Mock Resize-Partition { }
        Invoke-Cleanup
        Should -Invoke Resize-Partition -Times 1
    }
    It 'leaves free space alone when usbless never shrank C:' {
        Mock Test-LinuxInstalled { $false }
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false } }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]160GB } }
        Mock Resize-Partition { }
        Invoke-Cleanup
        Should -Invoke Resize-Partition -Times 0
    }
    It 'only removes the installer when Linux turns out to be installed' {
        Mock Test-LinuxInstalled { $true }
        Invoke-Cleanup
        $script:removed | Should -Be @([int64]160GB)
    }
    Context 'when the space cannot go back' {
        BeforeEach {
            Mock Test-LinuxInstalled { $false }
            Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; FastStartupWasOn = $true; BitLockerPaused = $true } }
            Mock Restore-FastStartup { }
            Mock Resume-BitLockerAfterUndo { }
            Mock Remove-Item { }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $StatePath }
            Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]160GB } }
        }
        It 'finishes the rest and reports it when the resize fails' {
            Mock Resize-Partition { throw 'Size Not Supported' }
            { Invoke-Cleanup } | Should -Not -Throw
            Should -Invoke Restore-FastStartup -Times 1
            Should -Invoke Resume-BitLockerAfterUndo -Times 1
            Should -Invoke Remove-Item -ParameterFilter { $LiteralPath -eq $StatePath } -Times 1
            $Sync.SpaceNote | Should -BeLike '*stays free*'
        }
        It 'finishes the rest and reports it when the drive has gone' {
            Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; FastStartupWasOn = $true; BitLockerPaused = $false; DiskGuid = '{disk-4}'; TargetKind = 'volume'; TargetOffset = [int64]1GB; OnWindowsDisk = $false } }
            Mock Get-StateDisk { 4 }
            Mock Get-PartitionAt { $null }
            Mock Resize-Partition { }
            { Invoke-Cleanup } | Should -Not -Throw
            Should -Invoke Resize-Partition -Times 0
            Should -Invoke Restore-FastStartup -Times 1
            Should -Invoke Remove-Item -ParameterFilter { $LiteralPath -eq $StatePath } -Times 1
            $Sync.SpaceNote | Should -BeLike '*stays free*'
        }
        It 'still forgets the setup when a setting cannot go back' {
            Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]100GB } }
            Mock Restore-FastStartup { throw 'no' }
            { Invoke-Cleanup } | Should -Not -Throw
            Should -Invoke Resume-BitLockerAfterUndo -Times 1
            Should -Invoke Remove-Item -ParameterFilter { $LiteralPath -eq $StatePath } -Times 1
        }
        It 'has nothing to report when the space went back' {
            Mock Resize-Partition { }
            Invoke-Cleanup
            $Sync.SpaceNote | Should -BeNullOrEmpty
        }
        It 'still stops when a partition could not be removed, because trying again can help' {
            Mock Remove-PartitionAt { throw 'in use' }
            { Invoke-Cleanup } | Should -Throw 'in use'
            Should -Invoke Remove-Item -Times 0
        }
    }
}

Describe 'Removing one Linux when another shares Windows'' EFI partition' {
    BeforeAll {
        $linuxType = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
        function New-PondEntry { [pscustomobject]@{ Number = 3; Description = 'Pond'; PartitionGuid = '{esp}'; Path = '\EFI\pond\shimx64.efi' } }
        function New-MintEntry { [pscustomobject]@{ Number = 4; Description = 'Linux Mint'; PartitionGuid = '{esp}'; Path = '\EFI\ubuntu\shimx64.efi' } }
    }
    BeforeEach {
        $script:esp = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$esp\EFI\pond", "$esp\EFI\ubuntu" -Force | Out-Null
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-WindowsEsp { [pscustomobject]@{ Guid = '{esp}' } }
        Mock Use-Esp { & $Action $script:esp }
        Mock Get-LinuxDisks { }
        Mock Get-Disk {
            if ($null -ne $Number) { [pscustomobject]@{ Number = $Number[0]; Guid = "{disk-$($Number[0])}" } }
            else { [pscustomobject]@{ Number = 0; Guid = '{disk-0}' }; [pscustomobject]@{ Number = 1; Guid = '{disk-1}' } }
        }
        Mock Get-Partition {
            if ($DiskNumber -contains 0) {
                [pscustomobject]@{ Guid = '{esp}'; DiskNumber = 0; GptType = $EspType; Size = [int64]100MB; Offset = [int64]1MB }
                [pscustomobject]@{ Guid = '{pond}'; DiskNumber = 0; GptType = $linuxType; Size = [int64]40GB; Offset = [int64]200GB }
            } else {
                [pscustomobject]@{ Guid = '{mint}'; DiskNumber = 1; GptType = $linuxType; Size = [int64]60GB; Offset = [int64]1GB }
            }
        }
        Mock Get-FileSystemUuid { if ($Partition.Guid -eq '{pond}') { '11111111-1111-1111-1111-111111111111' } else { '22222222-2222-2222-2222-222222222222' } }
        Mock Get-BootEntries {
            [pscustomobject]@{ Number = 0; Description = 'Windows Boot Manager'; PartitionGuid = '{esp}'; Path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
            New-MintEntry
            New-PondEntry
        }
    }
    It 'takes only the loader that names the system being removed, and the right name' {
        Set-Content "$esp\EFI\pond\grub.cfg" "search.fs_uuid 11111111-1111-1111-1111-111111111111 root hd0,gpt3"
        Set-Content "$esp\EFI\ubuntu\grub.cfg" "search.fs_uuid 22222222-2222-2222-2222-222222222222 root hd1,gpt1"
        $found = Find-OtherSystem 0
        $found.Name | Should -Be 'Pond'
        @($found.Entries).Number | Should -Be @(3)
        $found.Kept | Should -Be 'Linux Mint'
        @($found.Partitions).Guid | Should -Be @('{pond}')
    }
    It 'keeps every loader and says so when it cannot tie them to the system' {
        $found = Find-OtherSystem 0
        @($found.Entries).Count | Should -Be 0
        $found.Kept | Should -Be @('Linux Mint', 'Pond')
        $found.Name | Should -Be 'the other Linux'
    }
    It 'keeps them too when the EFI partition cannot be read' {
        Mock Use-Esp { throw 'blocked' }
        @((Find-OtherSystem 0).Entries).Count | Should -Be 0
    }
    It 'needs nothing from the EFI partition when there is no other Linux they could belong to' {
        Mock Get-Disk { [pscustomobject]@{ Number = 0; Guid = '{disk-0}' } }
        Mock Get-BootEntries { New-PondEntry }
        $found = Find-OtherSystem 0
        $found.Name | Should -Be 'Pond'
        @($found.Entries).Number | Should -Be @(3)
        Should -Invoke Use-Esp -Times 0
    }
    It 'keeps them when a disk usbless put Linux on is not connected' {
        Mock Get-Disk { [pscustomobject]@{ Number = 0; Guid = '{disk-0}' } }
        Mock Get-LinuxDisks { '{disk-gone}' }
        Mock Get-BootEntries { New-PondEntry }
        (Find-OtherSystem 0).Kept | Should -Be 'Pond'
    }
    It 'leaves kept loaders on the EFI partition and in the startup menu when removing' {
        Mock Remove-PartitionByGuid { }
        Mock Set-Status { }
        Mock Get-OtherSystem { [pscustomobject]@{ Name = 'the other Linux'; Entries = @(); Kept = @('Linux Mint'); WindowsEsp = '{esp}'; OnWindowsDisk = $true; Partitions = @([pscustomobject]@{ Guid = '{pond}'; DiskNumber = 0; Size = [int64]40GB }) } }
        Remove-OtherSystem
        Should -Invoke Use-Esp -Times 0
        Test-Path "$esp\EFI\ubuntu" | Should -BeTrue
        Should -Invoke Remove-PartitionByGuid -ParameterFilter { $Guid -eq '{pond}' -and $DiskNumber -eq 0 } -Times 1
    }
}

Describe 'Remove-PartitionByGuid' {
    It 'removes it from the disk it was found on, not a clone with the same GUID' {
        Mock Get-Partition {
            if ($DiskNumber -contains 1) { [pscustomobject]@{ Guid = '{same}'; DiskNumber = 1; PartitionNumber = 5 } }
            else { [pscustomobject]@{ Guid = '{same}'; DiskNumber = 0; PartitionNumber = 2 } }
        }
        Mock Remove-Partition { }
        Remove-PartitionByGuid '{same}' 1
        Should -Invoke Remove-Partition -ParameterFilter { $DiskNumber -contains 1 -and $PartitionNumber -contains 5 } -Times 1
        Should -Invoke Remove-Partition -Times 1
    }
}

Describe 'Remove-PartitionAt' {
    BeforeEach {
        # Plain stubs for a disk whose numbers close up after a removal.
        $layout = New-Object Collections.ArrayList
        foreach ($item in @(
                @('windows', [int64]1GB, $true), @('boot', [int64]100GB, $false), @('root', [int64]101GB, $false),
                @('installer', [int64]160GB, $false), @('recovery', [int64]168GB, $false))) {
            [void]$layout.Add([pscustomobject]@{ Name = $item[0]; Offset = $item[1]; IsSystem = $false; IsBoot = $item[2] })
        }
        function Get-Partition {
            param($DiskNumber)
            $number = 0
            foreach ($item in @($layout)) {
                $number++
                $item | Add-Member -NotePropertyName PartitionNumber -NotePropertyValue $number -Force
                $item
            }
        }
        function Remove-Partition {
            param($DiskNumber, $PartitionNumber, $Confirm)
            $layout.RemoveAt([int]$PartitionNumber - 1)
        }
    }
    It 'keeps the recovery partition when numbers shift during a clean-up' {
        foreach ($offset in [int64]100GB, [int64]101GB, [int64]160GB) { Remove-PartitionAt 0 $offset }
        (@($layout | ForEach-Object { $_.Name }) -join ',') | Should -Be 'windows,recovery'
    }
    It 'does nothing when the partition has already gone' {
        Remove-PartitionAt 0 ([int64]500GB)
        $layout.Count | Should -Be 5
    }
    It 'refuses a partition Windows needs' {
        { Remove-PartitionAt 0 ([int64]1GB) } | Should -Throw '*Refusing*'
    }
}

Describe 'Secure Boot' {
    BeforeAll {
        # A minimal 64-bit EFI program, with a signature table holding the given text.
        function New-Efi([string]$Path, [string]$Signature) {
            $text = [Text.Encoding]::ASCII.GetBytes($Signature)
            $bytes = New-Object byte[] (1024 + $text.Length)
            $bytes[0] = 0x4D; $bytes[1] = 0x5A
            [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
            $header = 0x80 + 24
            [BitConverter]::GetBytes([uint16]0x20B).CopyTo($bytes, $header)
            if ($text.Length) {
                [BitConverter]::GetBytes([uint32]1024).CopyTo($bytes, $header + 112 + 32)
                [BitConverter]::GetBytes([uint32]$text.Length).CopyTo($bytes, $header + 112 + 36)
                $text.CopyTo($bytes, 1024)
            }
            [IO.File]::WriteAllBytes($Path, $bytes)
        }
        function New-Iso([string]$Loader, [string]$Kernel) {
            New-Item -ItemType Directory -Path 'TestDrive:\iso\EFI\BOOT', 'TestDrive:\iso\boot\grub', 'TestDrive:\iso\casper' -Force | Out-Null
            $root = (Resolve-Path 'TestDrive:\iso').ProviderPath
            New-Efi (Join-Path $root 'EFI\BOOT\BOOTX64.EFI') $Loader
            New-Efi (Join-Path $root 'casper\vmlinuz') $Kernel
            Set-Content -LiteralPath (Join-Path $root 'boot\grub\grub.cfg') -Value @('menuentry "Try" {', '    linux  /casper/vmlinuz  --- quiet', '}')
            $root
        }
        $ca2011 = 'Microsoft Corporation UEFI CA 2011'
    }
    BeforeEach {
        Mock Test-SecureBoot { $true }
        Mock Test-BitLockerOn { $false }
        Mock Get-SecureBootDb { "xx$ca2011 yy" }
    }
    It 'reads certificate names from a signed program, and nothing from an unsigned one' {
        $root = New-Iso $ca2011 ''
        Get-EfiSignature (Join-Path $root 'EFI\BOOT\BOOTX64.EFI') | Should -BeLike "*$ca2011*"
        Get-EfiSignature (Join-Path $root 'casper\vmlinuz') | Should -BeNullOrEmpty
    }
    It 'knows both third-party certificates, and not the Windows or option ROM ones' {
        Get-UefiAuthorities "$ca2011 Microsoft UEFI CA 2023 Microsoft Option ROM UEFI CA 2023 Windows UEFI CA 2023" |
            Should -Be @($ca2011, 'Microsoft UEFI CA 2023')
    }
    It 'has nothing to say about an ISO this PC will start' {
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeNullOrEmpty
    }
    It 'does not look when Secure Boot is off' {
        Mock Test-SecureBoot { $false }
        Get-SecureBootProblem (New-Iso '' '') | Should -BeNullOrEmpty
    }
    It 'does not stop an install on a list it could not make sense of' {
        Mock Get-SecureBootDb { 'unreadable bytes' }
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeNullOrEmpty
    }
    It 'spots a boot loader this PC does not trust, such as a PC with only the 2023 certificate' {
        Mock Get-SecureBootDb { 'Microsoft UEFI CA 2023' }
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeLike "*doesn't trust*"
    }
    It 'accepts a boot loader signed by two authorities when one is trusted' {
        Mock Get-SecureBootDb { 'Microsoft UEFI CA 2023' }
        Get-SecureBootProblem (New-Iso "$ca2011 Microsoft UEFI CA 2023" 'Canonical') | Should -BeNullOrEmpty
    }
    It 'does not guess when the firmware will not share its list' {
        Mock Get-SecureBootDb { $null }
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeNullOrEmpty
    }
    It 'spots an unsigned boot loader' {
        Get-SecureBootProblem (New-Iso '' 'Canonical') | Should -BeLike "*boot loader isn't signed*"
    }
    It 'spots an unsigned kernel, as on Pop!_OS' {
        Get-SecureBootProblem (New-Iso $ca2011 '') | Should -BeLike "*kernel isn't signed*"
    }
    It 'mentions the recovery key when BitLocker is on' {
        Mock Test-BitLockerOn { $true }
        Get-SecureBootProblem (New-Iso '' '') | Should -BeLike '*recovery key*'
    }
    It 'stops Pop!_OS before the download' {
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'pop') } | Should -Throw '*Secure Boot*'
    }
    It 'lets other systems through to the ISO check' {
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'ubuntu') } | Should -Not -Throw
    }
    It 'stops CachyOS and Arch before the download, whose loaders have no signature' {
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'cachyos') } | Should -Throw '*Secure Boot*'
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'arch') } | Should -Throw '*Secure Boot*'
    }
    It 'lets the signed systems through to the ISO check' {
        foreach ($id in 'zorin', 'debian', 'fedora', 'ultramarine') {
            { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq $id) } | Should -Not -Throw
        }
    }
    It 'spots an unsigned kernel in a Fedora-style menu' {
        $root = (New-Iso $ca2011 'Canonical')
        Remove-Item (Join-Path $root 'boot\grub\grub.cfg')
        New-Item -ItemType Directory -Path (Join-Path $root 'boot\grub2'), (Join-Path $root 'boot\x86_64\loader') -Force | Out-Null
        Set-Content (Join-Path $root 'boot\grub2\grub.cfg') "menuentry 'a' {`n`tlinux (`$root)/boot/x86_64/loader/linux quiet`n}"
        New-Efi (Join-Path $root 'boot\x86_64\loader\linux') ''
        Get-SecureBootProblem $root | Should -BeLike "*kernel isn't signed*"
    }
}

Describe 'Get-Blockers' {
    BeforeEach {
        Mock Test-Uefi { $true }
        Mock Get-CimInstance { [pscustomobject]@{ Architecture = 9 } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'GPT'; BusType = 'NVMe' } }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy' } }
    }
    It 'has nothing to say on a normal PC' {
        @(Get-Blockers).Count | Should -Be 0
    }
    It 'stops on Legacy BIOS' {
        Mock Test-Uefi { $false }
        Get-Blockers | Should -BeLike '*Legacy BIOS*'
    }
    It 'stops on ARM' {
        Mock Get-CimInstance { [pscustomobject]@{ Architecture = 12 } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Get-Blockers | Should -BeLike '*ARM*'
    }
    It 'stops on an MBR disk' {
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'MBR'; BusType = 'SATA' } }
        Get-Blockers | Should -BeLike '*MBR*'
    }
    It 'stops on a damaged volume' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Unhealthy' } }
        Get-Blockers | Should -BeLike '*chkdsk*'
    }
}

Describe 'Assert-EspRoom' {
    BeforeEach {
        $source = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'BOOTX64.EFI') -Value 'usbless'
        $root = [IO.Path]::GetPathRoot("$TestDrive")
    }
    It 'is happy when the boot loader fits, whatever the system' {
        { Assert-EspRoom $root $source } | Should -Not -Throw
    }
    It 'counts what the Linux installer will add, and says how much is free' {
        { Assert-EspRoom $root $source 2000000000 } | Should -Throw '*too full*MB is free*'
    }
    It 'keeps room for the files Anaconda doesn''t notice failing to copy' {
        foreach ($id in 'fedora', 'ultramarine') { (Get-Catalog | Where-Object Id -eq $id).EspLinuxMB | Should -BeGreaterOrEqual 21 }
        (Get-Catalog | Where-Object Id -eq 'ubuntu').EspLinuxMB | Should -Be 0
    }
}

Describe 'Assert-EspWritable' {
    BeforeEach {
        $root = Join-Path $TestDrive 'esp'
        New-Item -ItemType Directory -Path "$root\EFI" -Force | Out-Null
    }
    It 'leaves nothing behind' {
        Assert-EspWritable $root
        @(Get-ChildItem "$root\EFI").Count | Should -Be 0
    }
    It 'names security software when a write is refused' {
        Mock Set-Content { throw 'Access denied' }
        { Assert-EspWritable $root } | Should -Throw '*Security software*'
    }
}

Describe 'Get-OtherInstallers' {
    BeforeEach {
        $usbStick = Join-Path $TestDrive 'usb\'
        $plain = Join-Path $TestDrive 'plain\'
        New-Item -ItemType Directory -Path "$usbStick.disk", $plain -Force | Out-Null
        Set-Content "$usbStick.disk\info" 'Ubuntu'
    }
    It 'finds an installer on a USB stick, and not on other drives' {
        Mock Get-Volume {
            [pscustomobject]@{ DriveType = 'Removable'; FileSystemLabel = 'Ubuntu'; Path = $usbStick; DriveLetter = 'E' }
            [pscustomobject]@{ DriveType = 'Fixed'; FileSystemLabel = 'Data'; Path = $plain; DriveLetter = 'D' }
        }
        $found = @(Get-OtherInstallers)
        $found.Count | Should -Be 1
        $found[0].Usb | Should -BeTrue
        $found[0].Name | Should -Be 'drive E:'
    }
    It 'ignores usbless''s own installer and mounted ISOs' {
        Mock Get-Volume {
            [pscustomobject]@{ DriveType = 'Fixed'; FileSystemLabel = 'USBLINSTALL'; Path = $usbStick; DriveLetter = 'H' }
            [pscustomobject]@{ DriveType = 'CD-ROM'; FileSystemLabel = 'Ubuntu'; Path = $usbStick; DriveLetter = 'F' }
        }
        @(Get-OtherInstallers).Count | Should -Be 0
    }
}

Describe 'Get-Warnings' {
    BeforeEach {
        Mock Get-OtherInstallers { }
        Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = [int64]16GB } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ BusType = 'NVMe' } }
        Mock Test-RestartPending { $false }
        Mock Test-BitLockerOn { $false }
    }
    It 'has nothing to say on a normal PC' {
        @(Get-Warnings).Count | Should -Be 0
    }
    It 'asks for the charger on battery' {
        Mock Get-CimInstance { [pscustomobject]@{ BatteryStatus = 1; EstimatedChargeRemaining = 40 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Get-Warnings | Should -BeLike '*charger*40%*'
    }
    It 'does not mind a battery on AC power' {
        Mock Get-CimInstance { [pscustomobject]@{ BatteryStatus = 2; EstimatedChargeRemaining = 0 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        @(Get-Warnings).Count | Should -Be 0
    }
    It 'asks to unplug a USB installer' {
        Mock Get-OtherInstallers { [pscustomobject]@{ Name = 'drive E:'; Usb = $true } }
        Get-Warnings | Should -BeLike '*Unplug drive E:*'
    }
    It 'warns about RAID mode' {
        Mock Get-Disk { [pscustomobject]@{ BusType = 'RAID' } }
        Get-Warnings | Should -BeLike '*RAID*'
    }
    It 'warns about a pending update and BitLocker' {
        Mock Test-RestartPending { $true }
        Mock Test-BitLockerOn { $true }
        @(Get-Warnings).Count | Should -Be 2
    }
}

Describe 'Suspend-BitLockerForRestart' {
    BeforeEach {
        Mock Suspend-BitLockerForSetup { $true }
        Mock Test-BitLockerOn { $false }
    }
    It 'pauses BitLocker that has come back on, and remembers' {
        Mock Test-BitLockerOn { $true }
        $state = [pscustomobject]@{ BitLockerPaused = $false }
        Suspend-BitLockerForRestart $state
        Should -Invoke Suspend-BitLockerForSetup -Times 1
        $state.BitLockerPaused | Should -BeTrue
    }
    It 'leaves a PC without BitLocker alone' {
        Suspend-BitLockerForRestart ([pscustomobject]@{ BitLockerPaused = $false })
        Should -Invoke Suspend-BitLockerForSetup -Times 0
    }
}

Describe 'Get-BootMenuKey' {
    It 'knows MSI, the laptop this was built on' {
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = 'Micro-Star International Co., Ltd.' } }
        Get-BootMenuKey | Should -Be 'F11'
    }
    It 'lists the usual keys for an unknown maker' {
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = 'Someone Else' } }
        Get-BootMenuKey | Should -BeLike '*F12*'
    }
}

Describe 'Get-ReturnedHelp' {
    BeforeEach {
        Mock Read-State { [pscustomobject]@{ Distro = 'Ubuntu'; BootNumber = 7 } }
        Mock Get-BootMenuKey { 'F11' }
        Mock Test-SecureBoot { $true }
        Mock Test-BootNextIgnored { $false }
        Mock Test-EntryDropped { $false }
    }
    It 'points at the boot menu when the firmware ignored the one-time start' {
        Mock Test-BootNextIgnored { $true }
        (Get-ReturnedHelp).Steps -join ' ' | Should -BeLike '*ignored*F11*'
    }
    It 'says when the firmware removed the entry, not to change Secure Boot' {
        Mock Test-EntryDropped { $true }
        $steps = (Get-ReturnedHelp).Steps -join ' '
        $steps | Should -BeLike '*Boot Order Lock*'
        $steps | Should -Not -BeLike '*Secure Boot*'
    }
    It 'points at Secure Boot when the firmware tried and it is on' {
        (Get-ReturnedHelp).Steps -join ' ' | Should -BeLike '*Secure Boot may have*'
    }
    It 'points at the boot menu when Secure Boot is off' {
        Mock Test-SecureBoot { $false }
        (Get-ReturnedHelp).Steps -join ' ' | Should -BeLike '*F11*'
    }
    It 'copes with a setup that has no startup entry yet' {
        Test-BootNextIgnored ([pscustomobject]@{ BootNumber = $null }) | Should -BeFalse
    }
}

Describe 'Get-Steps' {
    It 'names the partitions usbless made for a prepared system' {
        $steps = (Get-Steps (Get-Catalog | Where-Object Id -eq 'elementary') 60).Steps -join ' '
        $steps | Should -BeLike "*$RootLabel*"
        $steps | Should -BeLike "*$BootLabel*"
        $steps | Should -BeLike '*59 GB*'
    }
    It 'warns against Erase disk for a free space system' {
        ((Get-Steps (Get-Catalog | Where-Object Id -eq 'ubuntu') 60).Steps -join ' ') | Should -BeLike '*Erase disk*'
    }
    It 'warns against wiping the drive, and gives the size, on every system with its own steps' {
        foreach ($distro in Get-Catalog | Where-Object Steps) {
            $steps = (Get-Steps $distro 60).Steps -join ' '
            $steps | Should -BeLike '*60 GB*'
            $steps | Should -Not -BeLike '*{GB}*'
            $steps | Should -Match "Don't (choose|change)"
        }
    }
    It 'uses the words on Fedora''s and Ultramarine''s installer screens' {
        foreach ($id in 'fedora', 'ultramarine') {
            ((Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60).Steps -join ' ') | Should -BeLike '*Share disk with other operating systems*Use entire disk*'
        }
    }
    It 'needs no Terminal for Fedora and Ultramarine, and explains the warning about the EFI partition' {
        foreach ($id in 'fedora', 'ultramarine') {
            $steps = (Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60).Steps -join ' '
            $steps | Should -Not -BeLike '*Terminal*'
            $steps | Should -Not -BeLike '*umount*'
            $steps | Should -BeLike '*/boot/efi*carry on*'
        }
    }
    It 'says plainly that Arch installs in a terminal' {
        $steps = (Get-Steps (Get-Catalog | Where-Object Id -eq 'arch') 60).Steps -join ' '
        $steps | Should -BeLike '*no graphical installer*archinstall*Manual Partitioning*'
    }
    It 'tells people to press Enter at Debian''s menu, which has no timeout' {
        ((Get-Steps (Get-Catalog | Where-Object Id -eq 'debian') 60).Steps -join ' ') | Should -BeLike '*press Enter on **Live system***'
    }
    It 'tells CachyOS to use GRUB, whose files fit on the EFI partition' {
        ((Get-Steps (Get-Catalog | Where-Object Id -eq 'cachyos') 60).Steps -join ' ') | Should -BeLike '*Bootloader*GRUB*'
    }
}

Describe 'Assert-NoBitLocker' {
    BeforeAll {
        $omarchy = Get-Catalog | Where-Object Id -eq 'omarchy'
        function New-Head([string]$Id) { [byte[]](@(0xEB, 0x58, 0x90) + [Text.Encoding]::ASCII.GetBytes($Id) + (New-Object byte[] 501)) }
    }
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Partition { @([pscustomobject]@{ DiskNumber = 0; Offset = [int64]1MB }, [pscustomobject]@{ DiskNumber = 0; Offset = [int64]2GB }) }
        Mock Get-LetterOf { 'C' }
    }
    It 'knows BitLocker by its mark, and nothing else by it' {
        Test-BitLockerHead (New-Head '-FVE-FS-') | Should -BeTrue
        Test-BitLockerHead (New-Head 'NTFS    ') | Should -BeFalse
        Test-BitLockerHead (New-Object byte[] 4) | Should -BeFalse
    }
    It 'lets a disk through with BitLocker fully off' {
        Mock Read-PartitionHead { New-Head 'NTFS    ' }
        { Assert-NoBitLocker $omarchy '' } | Should -Not -Throw
    }
    It 'refuses BitLocker that is on or only paused, naming the drive, and says it won''t turn it off' {
        Mock Read-PartitionHead { New-Head '-FVE-FS-' } -ParameterFilter { [int64]$Partition.Offset -eq [int64]2GB }
        Mock Read-PartitionHead { New-Head 'NTFS    ' }
        { Assert-NoBitLocker $omarchy '' } | Should -Throw "Drive C:*Pausing it isn't enough*finished decrypting*won't do this for you*"
    }
    It 'refuses when it can''t look' {
        Mock Read-PartitionHead { throw 'no' }
        { Assert-NoBitLocker $omarchy '' } | Should -Throw "*couldn't check*"
    }
    It 'doesn''t look for other systems, for which usbless pauses it' {
        Mock Read-PartitionHead { New-Head '-FVE-FS-' }
        { Assert-NoBitLocker (Get-Catalog | Where-Object Id -eq 'arch') '' } | Should -Not -Throw
        Should -Invoke Read-PartitionHead -Times 0
    }
}

Describe 'Assert-SystemFitsSpace' {
    It 'asks for what Omarchy''s installer needs, with room for its rounding' {
        $omarchy = Get-Catalog | Where-Object Id -eq 'omarchy'
        { Assert-SystemFitsSpace $omarchy 32 } | Should -Throw '*at least 33 GB*'
        { Assert-SystemFitsSpace $omarchy 33 } | Should -Not -Throw
    }
    It 'leaves the others to the usual limit' {
        { Assert-SystemFitsSpace (Get-Catalog | Where-Object Id -eq 'arch') 25 } | Should -Not -Throw
    }
}

Describe 'Systems whose installer can''t use free space on its own disk' {
    BeforeAll { $ubiquity = @('zorin', 'mint-cinnamon', 'mint-xfce', 'mint-mate') }
    It 'refuses every one not seen to the end, next to Windows and on a second disk, with the reason' {
        foreach ($id in $ubiquity | Where-Object { $_ -notin $UbiquityProven }) {
            $distro = Get-Catalog | Where-Object Id -eq $id
            { Assert-SystemFitsDrive $distro '' } | Should -Throw "*$($distro.Name)*won't make a partition on the disk it starts from*"
            { Assert-SystemFitsDrive $distro 'gap:{disk-1}:1048576' } | Should -Throw '*next to Windows or on a second disk*'
        }
    }
    It 'offers one seen to the end on the disk Windows is on, through usbless''s own partition' {
        foreach ($id in $UbiquityProven) {
            $distro = Get-Catalog | Where-Object Id -eq $id
            $distro.Refused | Should -BeNullOrEmpty
            $distro.Strategy | Should -Be 'prepared'
            Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
            Mock Resolve-Target { [pscustomobject]@{ Partition = [pscustomobject]@{ DiskNumber = 0 } } }
            { Assert-SystemFitsDrive $distro '' } | Should -Not -Throw
        }
    }
    It 'still refuses one seen to the end on a second disk, which hasn''t been' {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Resolve-Target { [pscustomobject]@{ Partition = [pscustomobject]@{ DiskNumber = 1 } } }
        foreach ($id in $UbiquityProven) {
            { Assert-SystemFitsDrive (Get-Catalog | Where-Object Id -eq $id) 'gap:{disk-1}:1048576' } | Should -Throw "usbless hasn't got * to finish on a second disk yet*"
        }
    }
    It 'gives the steps in the installer''s words, with the size it shows, and says what starts next' {
        foreach ($id in $UbiquityProven) {
            $result = Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60 ([pscustomobject]@{ OnWindowsDisk = $true })
            ($result.Steps -join ' ') | Should -BeLike '*Installation type*63350 MB*Change...*Ext4 journaling file system*Format the partition*Mount point***/***Device for boot loader installation*Install Now*Continue*'
            ($result.Steps -join ' ') | Should -Not -Match '\{(GB|ROOTMB|DISK)\}'
            ($result.Notes -join ' ') | Should -BeLike '*starts*first*Windows Boot Manager*bootx64.efi*'
        }
    }
    It 'stops anything marked refused, wherever it was going, with its reason' {
        { Assert-SystemFitsDrive ([pscustomobject]@{ Name = 'Test'; Refused = 'Not this one.' }) '' } | Should -Throw 'Not this one.'
    }
    It 'still offers replacing Windows with Zorin OS, where that erase was seen' {
        (Get-Catalog | Where-Object Id -eq 'zorin').FullDisk | Should -Not -BeNullOrEmpty
    }
    It 'tells the window, and refuses nothing else' {
        $engine = New-Object Usbless.Engine
        try {
            (@($engine.GetCatalog() | Where-Object Refused | ForEach-Object { $_.Id } | Sort-Object) -join ',') | Should -Be (@($ubiquity | Where-Object { $_ -notin $UbiquityProven } | Sort-Object) -join ',')
            @($engine.GetCatalog() | Where-Object WindowsDiskOnly | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @(@('cachyos', 'debian', 'fedora-kde') + $UbiquityProven | Sort-Object)
        } finally { $engine.Dispose() }
    }
}

Describe 'Get-EspLinuxMB' {
    It 'keeps room on Windows'' EFI partition for <id>, wherever Linux goes' -ForEach @(@{ id = 'arch'; mb = 20 }) {
        Get-EspLinuxMB (Get-Catalog | Where-Object Id -eq $id) $true | Should -Be $mb
        Get-EspLinuxMB (Get-Catalog | Where-Object Id -eq $id) $false | Should -Be $mb
    }
    It 'asks for 25 MB for <id> on the disk Windows is on, and none on a second disk, where it makes its own' -ForEach @(@{ id = 'fedora' }, @{ id = 'ultramarine' }) {
        Get-EspLinuxMB (Get-Catalog | Where-Object Id -eq $id) $true | Should -Be 25
        Get-EspLinuxMB (Get-Catalog | Where-Object Id -eq $id) $false | Should -Be 0
    }
    It 'asks for nothing for a system that says nothing' {
        Get-EspLinuxMB (Get-Catalog | Where-Object Id -eq 'ubuntu') $false | Should -Be 0
    }
}

Describe 'Arch on a second disk' {
    It 'chooses both disks, puts Linux on the second and the mountpoint on Windows'' EFI partition' {
        $steps = Get-Steps (Get-Catalog | Where-Object Id -eq 'arch') 60 ([pscustomobject]@{ OnWindowsDisk = $false; DiskName = 'WD Blue'; DiskGB = 1000 })
        ($steps.Steps -join ' ') | Should -BeLike '*Manual Partitioning*Select disks for the installation*WD Blue (1000 GB)*disk Windows is on*WD Blue (1000 GB)*60 GB*ext4*disk Windows is on*fat32*/boot/efi*unformatted*Grub*'
        ($steps.Notes -join ' ') | Should -BeLike '*WD Blue (1000 GB)*'
        ($steps.Notes -join ' ') | Should -Not -BeLike '*{DISK}*'
    }
}

Describe 'Anaconda on a second disk' {
    It '<id> names the disk, and leaves out the warning about Windows'' small EFI partition' -ForEach @(@{ id = 'fedora' }, @{ id = 'ultramarine' }) {
        $steps = Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60 ([pscustomobject]@{ OnWindowsDisk = $false; DiskName = 'WD Blue'; DiskGB = 1000 })
        ($steps.Steps -join ' ') | Should -BeLike '*Select only **WD Blue (1000 GB)***Share disk with other operating systems*can be more than the 60 GB*Use entire disk*'
        ($steps.Steps -join ' ') | Should -Not -BeLike '*smaller than recommended*'
        ($steps.Notes -join ' ') | Should -BeLike '*from that disk*'
        ($steps.Notes -join ' ') | Should -BeLike '*Fast Boot*'
    }
    It '<id> keeps its usual steps on the disk Windows is on' -ForEach @(@{ id = 'fedora' }, @{ id = 'ultramarine' }) {
        $steps = Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60 ([pscustomobject]@{ OnWindowsDisk = $true })
        ($steps.Steps -join ' ') | Should -BeLike '*smaller than recommended*'
        ($steps.Notes -join ' ') | Should -Not -BeLike '*from that disk*'
    }
}

Describe 'Omarchy''s steps' {
    It 'warns off the option that erases Windows, and says how to get back to it' {
        $steps = Get-Steps (Get-Catalog | Where-Object Id -eq 'omarchy') 60 ([pscustomobject]@{ OnWindowsDisk = $true })
        ($steps.Steps -join ' ') | Should -BeLike '*Free space install*Full disk install*erases Windows*60 GB*Reboot Now*'
        ($steps.Notes -join ' ') | Should -BeLike '*limine-scan*'
    }
    It 'on a second disk, names it, warns off the Windows disk and says the space may be more than usbless''s' {
        $steps = Get-Steps (Get-Catalog | Where-Object Id -eq 'omarchy') 60 ([pscustomobject]@{ OnWindowsDisk = $false; DiskName = 'WD Blue'; DiskGB = 1000 })
        ($steps.Steps -join ' ') | Should -BeLike '*Select install disk*WD Blue (1000 GB)*disk Windows is on*Free space install*at least 60 GB*largest free space*Reboot Now*'
        ($steps.Steps -join ' ') | Should -Not -BeLike '*{DISK}*'
        ($steps.Notes -join ' ') | Should -BeLike '*boot menu*'
        ($steps.Notes -join ' ') | Should -BeLike '*Fast Boot*'
        ($steps.Notes -join ' ') | Should -Not -BeLike '*limine-scan*'
    }
    It 'counts its boot loader as a Linux one, so removing it takes the entry and its EFI partition too' {
        '\EFI\limine\limine_x64.efi' | Should -Match $LinuxLoaderPattern
    }
}

Describe 'Assert-SystemFitsDrive' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Resolve-Target { [pscustomobject]@{ Partition = [pscustomobject]@{ DiskNumber = 1 } } }
    }
    It 'refuses <id> on a second disk, with the reason, and claims nothing it has not seen' -ForEach @(
        @{ id = 'debian' }, @{ id = 'cachyos' }
    ) {
        { Assert-SystemFitsDrive (Get-Catalog | Where-Object Id -eq $id) 'gap:{disk-1}:1048576' } | Should -Throw "usbless hasn't got * to finish on a second disk yet*"
    }
    It 'lets them on another drive on the disk Windows is on' {
        Mock Resolve-Target { [pscustomobject]@{ Partition = [pscustomobject]@{ DiskNumber = 0 } } }
        { Assert-SystemFitsDrive (Get-Catalog | Where-Object Id -eq 'debian') 'volume:{disk-0}:1048576' } | Should -Not -Throw
    }
    It 'lets them on C: without looking anything up' {
        { Assert-SystemFitsDrive (Get-Catalog | Where-Object Id -eq 'debian') '' } | Should -Not -Throw
        Should -Invoke Resolve-Target -Times 0
    }
    It 'leaves systems with steps for a second disk alone' {
        { Assert-SystemFitsDrive (Get-Catalog | Where-Object Id -eq 'ubuntu') 'gap:{disk-1}:1048576' } | Should -Not -Throw
    }
    It 'lets <id> onto a second disk, having seen it install there' -ForEach @(@{ id = 'omarchy' }, @{ id = 'fedora' }, @{ id = 'ultramarine' }, @{ id = 'arch' }) {
        { Assert-SystemFitsDrive (Get-Catalog | Where-Object Id -eq $id) 'gap:{disk-1}:1048576' } | Should -Not -Throw
    }
}

Describe 'Remove-PersonalNames' {
    It 'takes out the user and computer names' {
        $text = "C:\Users\$env:USERNAME\Downloads on $env:COMPUTERNAME"
        (Remove-PersonalNames $text) | Should -Not -BeLike "*$env:USERNAME*"
        (Remove-PersonalNames $text) | Should -Not -BeLike "*$env:COMPUTERNAME*"
    }
}

Describe 'DiskProbe' {
    BeforeAll {
        function New-Head([int]$Offset, [byte[]]$Bytes) {
            $head = New-Object byte[] (128KB)
            [Array]::Copy($Bytes, 0, $head, $Offset, $Bytes.Length)
            , $head
        }
        function Get-Ascii([string]$Text) { , [Text.Encoding]::ASCII.GetBytes($Text) }
    }
    It 'recognises <name>' -ForEach @(
        @{ name = 'btrfs'; offset = 65600; text = '_BHRfS_M' }
        @{ name = 'xfs'; offset = 0; text = 'XFSB' }
        @{ name = 'lvm'; offset = 512; text = 'LABELONE' }
        @{ name = 'swap'; offset = 4086; text = 'SWAPSPACE2' }
        @{ name = 'bitlocker'; offset = 3; text = '-FVE-FS-' }
    ) {
        [Usbless.DiskProbe]::Identify((New-Head $offset (Get-Ascii $text))) | Should -Be $name
    }
    It 'recognises LUKS' {
        [Usbless.DiskProbe]::Identify((New-Head 0 ([byte[]](0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE)))) | Should -Be 'luks'
    }
    It 'recognises ext by its magic number and a sensible superblock' {
        $head = New-Head 1080 ([byte[]](0x53, 0xEF))
        [BitConverter]::GetBytes([uint32]1000).CopyTo($head, 1024)
        [Usbless.DiskProbe]::Identify($head) | Should -Be 'ext'
    }
    It 'is not fooled by the ext magic number alone' {
        [Usbless.DiskProbe]::Identify((New-Head 1080 ([byte[]](0x53, 0xEF)))) | Should -BeNullOrEmpty
    }
    It 'reads the ID of the file system GRUB would look for' {
        $head = New-Head 1080 ([byte[]](0x53, 0xEF))
        [BitConverter]::GetBytes([uint32]1000).CopyTo($head, 1024)
        ([byte[]](0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0)).CopyTo($head, 1128)
        [Usbless.DiskProbe]::IdentifyUuid($head) | Should -Be '12345678-9abc-def0-1234-56789abcdef0'
    }
    It 'has no ID to give for a partition it does not recognise' {
        [Usbless.DiskProbe]::IdentifyUuid((New-Object byte[] (128KB))) | Should -BeNullOrEmpty
    }
    It 'says nothing about an empty partition' {
        [Usbless.DiskProbe]::Identify((New-Object byte[] (128KB))) | Should -BeNullOrEmpty
    }
    It 'does not count BitLocker as Linux' {
        $LinuxSignatures | Should -Not -Contain 'bitlocker'
    }
}

Describe 'CancelGate' {
    It 'lets Cancel win before the disk stage, and stops the disk stage' {
        $gate = New-Object Usbless.CancelGate
        $gate.TryCancel() | Should -BeTrue
        $gate.EnterDiskStage() | Should -BeFalse
    }
    It 'refuses Cancel once the disk is changing' {
        $gate = New-Object Usbless.CancelGate
        $gate.EnterDiskStage() | Should -BeTrue
        $gate.TryCancel() | Should -BeFalse
    }
}

Describe 'Firmware after the Secure Boot check' {
    # Read only. Confirm-SecureBootUEFI turns the firmware privilege off when it finishes,
    # so usbless has to ask for it again. This found a bug that stopped installs on every PC.
    It 'can still read the startup menu' {
        try { [void][Usbless.Firmware]::BootOrderNumbers() } catch { Set-ItResult -Skipped -Because 'this PC has no readable firmware' }
        [void](Test-SecureBoot)
        { [void][Usbless.Firmware]::BootOrderNumbers() } | Should -Not -Throw
    }
}

Describe 'Assert-FirmwareAccess' {
    It 'passes when the startup menu can be changed' {
        Mock Test-FirmwareAccess { }
        { Assert-FirmwareAccess } | Should -Not -Throw
    }
    It 'explains itself and keeps the Windows error' {
        Mock Test-FirmwareAccess { throw 'Windows error 1314: A required privilege is not held by the client' }
        { Assert-FirmwareAccess } | Should -Throw "*startup menu*Nothing has been changed*1314*"
    }
    It 'stops an install before the download' {
        Mock Test-System { }
        Mock Get-InstallStatus { 'none' }
        Mock Assert-SecureBootAllows { }
        Mock Test-FirmwareAccess { throw 'refused' }
        Mock Resolve-Download { }
        { Invoke-Install 'ubuntu' '' 40 } | Should -Throw '*startup menu*'
        Should -Invoke Resolve-Download -Times 0
    }
}

Describe 'Engine' {
    It 'writes the reason a command stopped to the log' {
        $engine = New-Object Usbless.Engine
        try {
            $invoke = [Usbless.Engine].GetMethod('Invoke', [Reflection.BindingFlags]'NonPublic,Instance')
            { $invoke.Invoke($engine, @('Get-NoSuchUsblessCommand', $null)) } | Should -Throw
            ($engine.Log -join "`n") | Should -BeLike '*Stopped:*Get-NoSuchUsblessCommand*'
        } finally { $engine.Dispose() }
    }
    It 'tells the window when a restart is usbless''s own' {
        $engine = New-Object Usbless.Engine
        try {
            $engine.RoomRestarting | Should -BeFalse
            $engine.Sync['RoomRestarting'] = $true
            $engine.RoomRestarting | Should -BeTrue
        } finally { $engine.Dispose() }
    }
    It 'keeps a missing value missing, so a sentence can leave it out' {
        $engine = New-Object Usbless.Engine
        try {
            $catalog = $engine.GetCatalog()
            $null -eq ($catalog | Where-Object Id -eq 'mint-cinnamon').Version | Should -BeTrue
            ($catalog | Where-Object Id -eq 'ubuntu').Version | Should -Be '26.04 LTS'
        } finally { $engine.Dispose() }
    }
}

Describe 'Firmware load option' {
    It 'lays the entry out the way UEFI expects' {
        $guid = [guid]'11111111-2222-3333-4444-555555555555'
        $option = [Usbless.Firmware]::LoadOption('A', 1, 2048, 4096, $guid, '\EFI\usbless\BOOTX64.EFI')

        [BitConverter]::ToUInt32($option, 0) | Should -Be 1                # LOAD_OPTION_ACTIVE
        [Text.Encoding]::Unicode.GetString($option, 6, 2) | Should -Be 'A' # description
        $path = 10                                                         # after attributes, length, "A\0"
        $option[$path] | Should -Be 4                                      # media device path
        $option[$path + 1] | Should -Be 1                                  # hard drive
        [BitConverter]::ToUInt16($option, $path + 2) | Should -Be 42
        [BitConverter]::ToUInt32($option, $path + 4) | Should -Be 1        # partition number
        [BitConverter]::ToUInt64($option, $path + 8) | Should -Be 2048     # start
        [BitConverter]::ToUInt64($option, $path + 16) | Should -Be 4096    # size
        $option[$path + 40] | Should -Be 2                                 # GPT
        $option[$path + 41] | Should -Be 2                                 # GUID signature

        $file = $path + 42
        $option[$file + 1] | Should -Be 4                                  # file path node
        $option[($option.Length - 4)..($option.Length - 1)] -join ',' | Should -Be '127,255,4,0'   # end node
        [BitConverter]::ToUInt16($option, 4) | Should -Be ($option.Length - $path)                 # path length
    }
}

Describe 'Moving files' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3 } }
        Mock Get-SupportedSize { }
    }
    It 'tries again when Windows gives up straight away' {
        $script:codes = [Collections.Queue]::new(@(1223, 1223, 0))
        Mock Start-DefragRun { $script:codes.Dequeue() }
        Invoke-Defrag 'C:'
        Should -Invoke Start-DefragRun -Times 3
    }
    It 'gives up trying in the end, and carries on' {
        Mock Start-DefragRun { 1223 }
        Invoke-Defrag 'C:'
        Should -Invoke Start-DefragRun -Times $DefragTries
    }
    It 'runs once when it worked' {
        Mock Start-DefragRun { 0 }
        Invoke-Defrag 'C:'
        Should -Invoke Start-DefragRun -Times 1
    }
    It 'does not run again after its time ran out, with no code' {
        Mock Start-DefragRun { }
        Invoke-Defrag 'C:'
        Should -Invoke Start-DefragRun -Times 1
    }
}

Describe 'Whether hibernation is on' {
    It 'is on when a new Windows only has the default' {
        Mock Get-ItemProperty { [pscustomobject]@{ HibernateEnabledDefault = 1 } } -ParameterFilter { $Path -like '*Control\Power' }
        Test-HibernationOn | Should -BeTrue
    }
    It 'goes by what was set, over the default' {
        Mock Get-ItemProperty { [pscustomobject]@{ HibernateEnabled = 0; HibernateEnabledDefault = 1 } } -ParameterFilter { $Path -like '*Control\Power' }
        Test-HibernationOn | Should -BeFalse
    }
    It 'is off when nothing says so' {
        Mock Get-ItemProperty { [pscustomobject]@{ Other = 1 } } -ParameterFilter { $Path -like '*Control\Power' }
        Test-HibernationOn | Should -BeFalse
    }
}

Describe 'Make room''s tasks and copy' {
    BeforeAll { $RoomPath = Join-Path $TestDrive 'make-room.json' }
    BeforeEach {
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        Mock Test-HibernationOn { $true }
        Mock Test-EnoughMemoryWithoutPaging { $true }
        Mock Get-PagingSettings { @('?:\pagefile.sys') }
        Mock Set-Hibernation { }
        Mock Clear-ChangeJournal { }
        Mock New-ChangeJournal { }
        Mock Set-PagingOff { }
        Mock Restore-Paging { }
        Mock Invoke-Shutdown { }
        Mock Invoke-Defrag { }
        Mock Get-RestartCopy { "$env:ProgramData\usbless-restart-test\usbless.exe" }
        Mock Remove-RestartCopy { }
        Mock Remove-RoomTask { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }
        Mock Set-RoomTasks { }
    }
    It 'makes the tasks before restarting, and records the copy so it can go' {
        Mock Invoke-Shutdown { Should -Invoke Set-RoomTasks -Times 1 -Scope It }
        Start-MakeRoom
        Should -Invoke Invoke-Shutdown -Times 1
        (Read-RoomState).CopyFolder | Should -Be "$env:ProgramData\usbless-restart-test"
    }
    It 'puts everything back and does not restart if a task cannot be made' {
        Mock Set-RoomTasks { throw 'no tasks here' }
        { Start-MakeRoom } | Should -Throw '*no tasks here*'
        Should -Invoke Invoke-Shutdown -Times 0
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 1
        Should -Invoke Restore-Paging -Times 1
        Test-Path $RoomPath | Should -BeFalse
    }
    It 'puts everything back and does not restart if Windows did not keep a task' {
        Mock Get-ScheduledTask { }
        { Start-MakeRoom } | Should -Throw
        Should -Invoke Invoke-Shutdown -Times 0
        Should -Invoke Restore-Paging -Times 1
    }
    It 'does not restart if the protected copy cannot be made' {
        Mock Get-RestartCopy { throw 'no copy' }
        { Start-MakeRoom } | Should -Throw '*no copy*'
        Should -Invoke Invoke-Shutdown -Times 0
        Should -Invoke Restore-Paging -Times 1
    }
    It 'puts the settings back from the task when nobody came back to usbless' {
        Start-MakeRoom
        Restore-RoomFromTask
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 1
        Should -Invoke Restore-Paging -Times 1
        Should -Invoke New-ChangeJournal -Times 1
        Test-Path $RoomPath | Should -BeFalse
        Should -Invoke Remove-RestartCopy -ParameterFilter { $Folder -eq "$env:ProgramData\usbless-restart-test" }
        Should -Invoke Remove-RoomTask -ParameterFilter { $Name -eq $ResumeTaskName }
        Should -Invoke Remove-RoomTask -ParameterFilter { $Name -eq $RestoreTaskName }
    }
    It 'removes the tasks and the copy when the settings go back' {
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Remove-RoomTask -ParameterFilter { $Name -eq $RestoreTaskName } -Times 1
        Should -Invoke Remove-RestartCopy -ParameterFilter { $Folder -eq "$env:ProgramData\usbless-restart-test" } -Times 1
    }
}

Describe 'The copy the tasks run' {
    It 'is in a new folder that only administrators and SYSTEM can write to' {
        $parent = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory -Path $parent | Out-Null
        $copy = [Usbless.RestartCopy]::Create($parent)
        try {
            Test-Path -LiteralPath $copy | Should -BeTrue
            $folder = Split-Path $copy -Parent
            Split-Path $folder -Leaf | Should -BeLike 'usbless-restart-*'
            $rights = Get-Acl -LiteralPath $folder
            $rights.AreAccessRulesProtected | Should -BeTrue
            $writing = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,WriteAttributes,WriteExtendedAttributes,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
            $writers = @($rights.Access | Where-Object { ($_.FileSystemRights -band $writing) -ne 0 } |
                    ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
            ($writers | Sort-Object) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544'
            (Get-Item -LiteralPath $copy).Length | Should -Be (Get-Item -LiteralPath ([Usbless.RestartCopy]::RunningImage())).Length
        } finally {
            [IO.Directory]::Delete((Split-Path $copy -Parent), $true)
        }
    }
    It 'names a different folder each time, so nothing can be waiting in it' {
        $parent = Join-Path $TestDrive 'data2'
        New-Item -ItemType Directory -Path $parent | Out-Null
        $one = [Usbless.RestartCopy]::Create($parent)
        $two = [Usbless.RestartCopy]::Create($parent)
        $one | Should -Not -Be $two
        [IO.Directory]::Delete((Split-Path $one -Parent), $true)
        [IO.Directory]::Delete((Split-Path $two -Parent), $true)
    }
    It 'refuses to delete anything but one of its copies' {
        $keep = Join-Path $TestDrive 'keep'
        New-Item -ItemType Directory -Path $keep | Out-Null
        Remove-RestartCopy $keep
        Test-Path -LiteralPath $keep | Should -BeTrue
    }
    It 'makes the tasks with fixed arguments, the logon one elevated and for this user only' {
        $script:tasks = @{}
        Mock Register-ScheduledTask { $script:tasks[$TaskName] = @{ Action = $Action; Principal = $Principal; Trigger = $Trigger } }
        Set-RoomTasks "$env:ProgramData\usbless-restart-x\usbless.exe"
        $resume = $script:tasks[$ResumeTaskName]
        $resume.Action.Execute | Should -Be "$env:ProgramData\usbless-restart-x\usbless.exe"
        $resume.Action.Arguments | Should -BeNullOrEmpty
        $resume.Principal.RunLevel | Should -Be 'Highest'
        $resume.Trigger.UserId | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $restore = $script:tasks[$RestoreTaskName]
        $restore.Action.Arguments | Should -Be '--restore-room'
        $restore.Principal.UserId | Should -Be 'SYSTEM'
    }
}
