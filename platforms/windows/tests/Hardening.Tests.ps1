# Unit tests for what stops someone else's files, a crash or one failure from doing damage. Rights
# and links are real, on files under TestDrive. Those that change an owner need an elevated PowerShell.

BeforeDiscovery {
    $elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1') -WithUsbless
    Mock Write-Log { }

    # Windows lets an administrator hand something to the Users group, which stands in for an ordinary user.
    function Set-OwnedByUsers([string]$Path) { & icacls.exe $Path /setowner '*S-1-5-32-545' | Out-Null; if ($LASTEXITCODE) { throw "icacls said $LASTEXITCODE" } }
    function Set-OwnedByAdmins([string]$Path) { & icacls.exe $Path /setowner '*S-1-5-32-544' /T | Out-Null; if ($LASTEXITCODE) { throw "icacls said $LASTEXITCODE" } }
    function New-Folder([string]$Path) { New-Item -ItemType Directory -Path $Path -Force | Out-Null; $Path }
    function Get-Writers([string]$Path) {
        $writing = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
        (@((Get-Acl -LiteralPath $Path).Access | Where-Object { ($_.FileSystemRights -band $writing) -ne 0 } |
                ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }) | Sort-Object -Unique) -join ','
    }
}

Describe 'usbless''s folder' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'is made so that only administrators and SYSTEM can write there' -Skip:(-not $elevated) {
        [Usbless.StateFolder]::Protect($folder, $true) | Should -BeNullOrEmpty
        (Get-Acl -LiteralPath $folder).AreAccessRulesProtected | Should -BeTrue
        Get-Writers $folder | Should -Be 'S-1-5-18,S-1-5-32-544'
    }
    It 'is not made when it is only being checked' {
        [Usbless.StateFolder]::Protect($folder, $false) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $folder | Should -BeFalse
    }
    It 'takes over the folder an earlier build left, keeping what is in it' -Skip:(-not $elevated) {
        New-Folder "$folder\logs" | Out-Null
        Set-Content -LiteralPath "$folder\state.json" -Value '{"Distro":"Ubuntu"}'
        Set-Content -LiteralPath "$folder\logs\usbless.log" -Value 'a line'
        Set-OwnedByAdmins $folder
        (Get-Acl -LiteralPath $folder).AreAccessRulesProtected | Should -BeFalse
        [Usbless.StateFolder]::Protect($folder, $true) | Should -BeNullOrEmpty
        Get-Content -LiteralPath "$folder\state.json" -Raw | Should -BeLike '*Ubuntu*'
        Test-Path -LiteralPath "$folder\logs\usbless.log" | Should -BeTrue
        Get-Writers $folder | Should -Be 'S-1-5-18,S-1-5-32-544'
        Get-Writers "$folder\state.json" | Should -Be 'S-1-5-18,S-1-5-32-544'
    }
    It 'moves aside a make-room.json an ordinary user planted, and nothing else' -Skip:(-not $elevated) {
        New-Folder $folder | Out-Null
        Set-Content -LiteralPath "$folder\make-room.json" -Value '{"Phase":"ready","PagingOff":true,"Paging":["evil"]}'
        Set-Content -LiteralPath "$folder\state.json" -Value 'kept'
        Set-OwnedByAdmins $folder
        Set-OwnedByUsers "$folder\make-room.json"
        @([Usbless.StateFolder]::Protect($folder, $true)).Count | Should -Be 1
        Test-Path -LiteralPath "$folder\make-room.json" | Should -BeFalse
        Test-Path -LiteralPath "$folder\state.json" | Should -BeTrue
        @(Get-ChildItem -LiteralPath $TestDrive -Filter "$(Split-Path $folder -Leaf)-moved-*").Count | Should -Be 1
    }
    It 'moves aside a state.json.tmp an ordinary user planted' -Skip:(-not $elevated) {
        New-Folder $folder | Out-Null
        Set-Content -LiteralPath "$folder\state.json.tmp" -Value 'x'
        Set-OwnedByAdmins $folder
        Set-OwnedByUsers "$folder\state.json.tmp"
        [void][Usbless.StateFolder]::Protect($folder, $true)
        Test-Path -LiteralPath "$folder\state.json.tmp" | Should -BeFalse
    }
    It 'moves aside the whole folder when an ordinary user made it, and makes a new one' -Skip:(-not $elevated) {
        New-Folder $folder | Out-Null
        Set-Content -LiteralPath "$folder\make-room.json" -Value 'planted'
        Set-OwnedByUsers $folder
        @([Usbless.StateFolder]::Protect($folder, $true)).Count | Should -Be 1
        Test-Path -LiteralPath "$folder\make-room.json" | Should -BeFalse
        Get-Writers $folder | Should -Be 'S-1-5-18,S-1-5-32-544'
    }
    It 'renames a link in its place, without touching what it points at' -Skip:(-not $elevated) {
        $target = New-Folder (Join-Path $TestDrive "target-$([guid]::NewGuid().ToString('N'))")
        Set-Content -LiteralPath "$target\keep.txt" -Value 'keep'
        $before = Get-Writers $target
        & cmd.exe /c mklink /J $folder $target | Out-Null
        [void][Usbless.StateFolder]::Protect($folder, $true)
        (Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Be 0
        Test-Path -LiteralPath "$target\keep.txt" | Should -BeTrue
        Get-Writers $target | Should -Be $before
    }
    It 'moves aside a link to the logs, without touching what it points at' -Skip:(-not $elevated) {
        New-Folder $folder | Out-Null
        $target = New-Folder (Join-Path $TestDrive "target-$([guid]::NewGuid().ToString('N'))")
        Set-Content -LiteralPath "$target\keep.txt" -Value 'keep'
        $before = Get-Writers $target
        Set-OwnedByAdmins $folder
        & cmd.exe /c mklink /J "$folder\logs" $target | Out-Null
        @([Usbless.StateFolder]::Protect($folder, $true)).Count | Should -Be 1
        Test-Path -LiteralPath "$folder\logs" | Should -BeFalse
        Test-Path -LiteralPath "$target\keep.txt" | Should -BeTrue
        Get-Writers $target | Should -Be $before
    }
    It 'moves aside a file with the folder''s name' -Skip:(-not $elevated) {
        Set-Content -LiteralPath $folder -Value 'in the way'
        @([Usbless.StateFolder]::Protect($folder, $true)).Count | Should -Be 1
        (Get-Item -LiteralPath $folder -Force).PSIsContainer | Should -BeTrue
    }
    It 'has nothing to do the second time' -Skip:(-not $elevated) {
        [void][Usbless.StateFolder]::Protect($folder, $true)
        [Usbless.StateFolder]::Protect($folder, $true) | Should -BeNullOrEmpty
    }
    It 'leaves usbless''s own files alone once it is protected, with UAC off too, where they are the account''s' -Skip:(-not $elevated) {
        [void][Usbless.StateFolder]::Protect($folder, $true)
        Set-Content -LiteralPath "$folder\state.json" -Value 'kept'
        Set-OwnedByUsers "$folder\state.json"
        [Usbless.StateFolder]::Protect($folder, $true) | Should -BeNullOrEmpty
        Test-Path -LiteralPath "$folder\state.json" | Should -BeTrue
    }
    It 'does not count the account usbless runs as, whose programs need not be elevated' -Skip:(-not $elevated) {
        $file = Join-Path $TestDrive "mine-$([guid]::NewGuid().ToString('N'))"
        Set-Content -LiteralPath $file -Value 'x'
        & icacls.exe $file /setowner ([Security.Principal.WindowsIdentity]::GetCurrent().Name) | Out-Null
        [Usbless.StateFolder]::IsTrusted($file) | Should -BeFalse
    }
    It 'ignores the old state file when an ordinary user made it' -Skip:(-not $elevated) {
        New-Folder $folder | Out-Null
        $StatePath = "$folder\none.json"
        $LegacyStatePath = "$folder\state.json"
        Set-Content -LiteralPath $LegacyStatePath -Value '{"Distro":"planted"}'
        Set-OwnedByAdmins $folder
        (Read-State).Distro | Should -Be 'planted'
        Set-OwnedByUsers $LegacyStatePath
        Read-State | Should -BeNullOrEmpty
    }
}

Describe 'Writing a state file' {
    BeforeEach {
        $folder = New-Folder (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $path = "$folder\state.json"
    }
    It 'makes a file usbless can read, and leaves nothing else' {
        Write-StateFile $path '{"A":"é"}'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).A | Should -Be 'é'
        @(Get-ChildItem -LiteralPath $folder -Force).Name | Should -Be 'state.json'
    }
    It 'replaces what was there' {
        Write-StateFile $path 'one'
        Write-StateFile $path 'two'
        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'two'
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 1
    }
    It 'does not write through a temporary file that was waiting for it' {
        $StatePath = $path
        Set-Content -LiteralPath "$path.tmp" -Value 'waiting'
        Save-State ([pscustomobject]@{ A = 1 })
        (Get-Content -LiteralPath "$path.tmp" -Raw).Trim() | Should -Be 'waiting'
        (Read-State).A | Should -Be 1
    }
    It 'keeps the old file and leaves nothing behind when the swap fails' {
        Write-StateFile $path 'old'
        (Get-Item -LiteralPath $path).IsReadOnly = $true
        { Write-StateFile $path 'new' } | Should -Throw
        (Get-Item -LiteralPath $path).IsReadOnly = $false
        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'old'
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 1
    }
}

Describe 'The restart copy' {
    It 'is new every time, and never the folder usbless is running from' -Skip:(-not $elevated) {
        $ProgramData = New-Folder "$TestDrive\data"
        $one = Get-RestartCopy
        $two = Get-RestartCopy
        $one | Should -Not -Be $two
        Split-Path $one -Parent | Should -Not -Be ([Usbless.RestartCopy]::OwnFolder())
        [Usbless.RestartCopy]::IsCopyFolder((Split-Path $one -Parent), $ProgramData) | Should -BeTrue
    }
    It 'goes after the tasks use a new one, along with one from an earlier try' {
        $RoomPath = "$TestDrive\room-copy.json"
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        Save-RoomState ([pscustomobject]@{ Phase = 'restarting'; CopyFolder = 'C:\old' })
        $script:calls = @()
        Mock Get-RestartCopy { 'C:\new\usbless.exe' }
        Mock Set-RoomTasks { $script:calls += 'tasks' }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }
        Mock Remove-ItemProperty { }
        Mock Remove-RestartCopy { $script:calls += "remove $Folder" }
        Register-RunAfterRestart
        $script:calls | Should -Be @('tasks', 'remove C:\old')
        (Read-RoomState).CopyFolder | Should -Be 'C:\new'
    }
}

Describe 'Telling a real restart copy from a folder with its name' {
    It 'takes one usbless made' -Skip:(-not $elevated) {
        $parent = New-Folder "$TestDrive\parent1"
        $copy = Split-Path ([Usbless.RestartCopy]::Create($parent)) -Parent
        [Usbless.RestartCopy]::IsCopyFolder($copy, $parent) | Should -BeTrue
        [Usbless.RestartCopy]::IsCopyFolder($copy, "$parent\") | Should -BeTrue
    }
    It 'refuses the name anywhere else' -Skip:(-not $elevated) {
        $parent = New-Folder "$TestDrive\parent2"
        $copy = Split-Path ([Usbless.RestartCopy]::Create($parent)) -Parent
        [Usbless.RestartCopy]::IsCopyFolder($copy, "$TestDrive\elsewhere") | Should -BeFalse
    }
    It 'refuses another name in the right place' {
        $parent = New-Folder "$TestDrive\parent3"
        [Usbless.RestartCopy]::IsCopyFolder((New-Folder "$parent\other"), $parent) | Should -BeFalse
    }
    It 'refuses one an ordinary user owns' -Skip:(-not $elevated) {
        $parent = New-Folder "$TestDrive\parent4"
        $folder = New-Folder "$parent\usbless-restart-x"
        Set-OwnedByUsers $folder
        [Usbless.RestartCopy]::IsCopyFolder($folder, $parent) | Should -BeFalse
    }
    It 'refuses one that is not there' {
        [Usbless.RestartCopy]::IsCopyFolder("$TestDrive\usbless-restart-gone", $TestDrive) | Should -BeFalse
    }
}

Describe 'Which recorded partitions Clean up removes' {
    BeforeAll {
        $linuxRoot = '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}'
        $state = [pscustomobject]@{ DiskNumber = 0; Partitions = @([pscustomobject]@{ Role = 'root'; Offset = [int64]400GB; Size = [int64]60GB }) }
    }
    BeforeEach {
        $type = $BasicDataType
        Mock Get-StateDisk { 0 }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 5; Offset = [int64]400GB; Size = [int64]60GB; IsSystem = $false; IsBoot = $false; GptType = $type } }
        Mock Get-VolumeOf { $null }
        Mock Read-PartitionHead { New-Object byte[] 16 }
    }
    It 'removes one that is unformatted and blank' {
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 1
    }
    It 'keeps one it cannot read' {
        Mock Read-PartitionHead { throw 'no' }
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 0
    }
    It 'keeps one with anything written at its start, even if Windows has no idea what' {
        Mock Read-PartitionHead { [byte[]](0, 0, 7) }
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 0
    }
    It 'keeps one whose type says Linux, without having to read it' {
        $type = $linuxRoot
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 0
        Should -Invoke Read-PartitionHead -Times 0
    }
    It 'keeps one with a file system' {
        Mock Get-VolumeOf { [pscustomobject]@{ FileSystemType = 'NTFS' } }
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 0
    }
}

Describe 'Putting Make room back' {
    BeforeAll { $RoomPath = Join-Path $TestDrive 'make-room.json' }
    BeforeEach {
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        $script:order = @()
        Mock Test-HibernationOn { $true }
        Mock Test-EnoughMemoryWithoutPaging { $true }
        Mock Get-PagingSettings { @('?:\pagefile.sys') }
        Mock Set-Hibernation { }
        Mock Clear-ChangeJournal { }
        Mock New-ChangeJournal { }
        Mock Set-PagingOff { }
        Mock Restore-Paging { $script:order += 'paging' }
        Mock Register-RunAfterRestart { }
        Mock Unregister-RunAfterRestart { $script:order += 'tasks' }
        Mock Remove-RoomTask { }
        Mock Invoke-Shutdown { }
        Mock Invoke-Defrag { }
        Mock Get-LastBoot { [datetime]'2030-01-01' }
    }
    It 'removes the safety net only after the settings are back' {
        Start-MakeRoom
        Restore-RoomSettings
        $script:order | Should -Be @('paging', 'tasks')
        Test-Path -LiteralPath $RoomPath | Should -BeFalse
    }
    It 'keeps the file and the tasks when hibernation stays off' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        Restore-RoomSettings
        Test-Path -LiteralPath $RoomPath | Should -BeTrue
        Should -Invoke Unregister-RunAfterRestart -Times 0
        (Read-RoomState).RestoreTries | Should -Be 1
    }
    It 'keeps them when the paging file cannot go back, and only tries that again' {
        Start-MakeRoom
        Mock Restore-Paging { throw 'no' }
        Restore-RoomSettings
        $state = Read-RoomState
        $state.PagingOff | Should -BeTrue
        $state.Hibernation | Should -BeFalse
        Should -Invoke Unregister-RunAfterRestart -Times 0
    }
    It 'goes back to restoring rather than carrying on with Make room next time' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        Get-RoomPhase | Should -Be 'continue'
        Restore-RoomSettings
        Get-RoomPhase | Should -Be 'restore'
    }
    It 'finishes on a later try' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        Restore-RoomSettings
        Mock Test-HibernationOn { $true }
        Restore-RoomSettings
        Test-Path -LiteralPath $RoomPath | Should -BeFalse
        Should -Invoke Unregister-RunAfterRestart -Times 1
    }
    It 'gives up in the end, so it can''t go on for ever' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        for ($i = 1; $i -lt $RoomRestoreTries; $i++) {
            Restore-RoomSettings
            Test-Path -LiteralPath $RoomPath | Should -BeTrue
        }
        Restore-RoomSettings
        Test-Path -LiteralPath $RoomPath | Should -BeFalse
        Should -Invoke Unregister-RunAfterRestart -Times 1
    }
    It 'never throws for a failed restore, so it can''t stop usbless opening' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        Mock Restore-Paging { throw 'no' }
        Mock Save-RoomState { throw 'disk full' }
        { Restore-RoomSettings } | Should -Not -Throw
    }
    It 'keeps the task going while something is still off' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        Restore-RoomFromTask
        Should -Invoke Remove-RoomTask -Times 0
    }
    It 'will not start again over settings it could not put back' {
        Start-MakeRoom
        Mock Test-HibernationOn { $false }
        Mock Set-Hibernation { throw 'should not be turned off again' } -ParameterFilter { -not $On }
        { Start-MakeRoom } | Should -Throw '*turn back on*'
        (Read-RoomState).RestoreTries | Should -Be 1
    }
    Context 'with a damaged file' {
        BeforeEach { Set-Content -LiteralPath $RoomPath -Value '{"Phase":"resta' }
        It 'keeps the file and the tasks, and does not remove itself' {
            Restore-RoomFromTask
            Test-Path -LiteralPath $RoomPath | Should -BeTrue
            Should -Invoke Remove-RoomTask -Times 0
            Should -Invoke Unregister-RunAfterRestart -Times 0
        }
        It 'will not write over it with settings that are already off' {
            { Start-MakeRoom } | Should -Throw '*read what an earlier Make room*'
            (Get-Content -LiteralPath $RoomPath -Raw).Trim() | Should -Be '{"Phase":"resta'
            Should -Invoke Set-Hibernation -Times 0
        }
        It 'does not stop usbless opening' {
            Get-RoomPhase | Should -BeNullOrEmpty
        }
        It 'counts valid text that says nothing as damaged too' {
            Set-Content -LiteralPath $RoomPath -Value 'null'
            Test-RoomFileDamaged | Should -BeTrue
        }
    }
}

Describe 'Undo with Make room''s settings still off' {
    BeforeAll { $RoomPath = Join-Path $TestDrive 'make-room.json' }
    BeforeEach {
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false; FastStartupWasOn = $false; BitLockerPaused = $false } }
        Mock Unregister-RunAfterRestart { }
        Mock Get-BcdEntries { }
        Mock Get-FirmwareEntries { }
        Mock Use-Esp { }
        Mock Get-UsblessPartitions { }
        Mock Get-RecordedPartitions { }
        Mock Get-SpaceOwner { }
        Mock Test-LinuxInstalled { $false }
        Mock Test-Path { $false } -ParameterFilter { $Path -in @($StatePath, $LegacyStatePath) }
    }
    It 'keeps the safety net' {
        Set-Content -LiteralPath $RoomPath -Value '{"Phase":"ready"}'
        Invoke-Cleanup
        Should -Invoke Unregister-RunAfterRestart -Times 0
    }
    It 'removes the tasks when nothing is off' {
        Invoke-Cleanup
        Should -Invoke Unregister-RunAfterRestart -Times 1
    }
}

Describe 'Removing startup entries' {
    BeforeEach {
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false; FastStartupWasOn = $false; BitLockerPaused = $false } }
        Mock Unregister-RunAfterRestart { }
        Mock Get-BcdEntries { }
        Mock Get-FirmwareEntries { 1, 2 }
        Mock Remove-FirmwareEntry { if ($Number -eq 1) { throw 'firmware says no' } }
        Mock Use-Esp { }
        Mock Get-UsblessPartitions { [pscustomobject]@{ Label = 'USBLINSTALL'; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]160GB } } }
        Mock Get-RecordedPartitions { }
        Mock Get-SpaceOwner { }
        Mock Remove-PartitionAt { }
        Mock Test-LinuxInstalled { $false }
        Mock Test-Path { $false } -ParameterFilter { $Path -in @($StatePath, $LegacyStatePath) }
    }
    It 'carries on after one the firmware refuses' {
        { Invoke-Cleanup } | Should -Not -Throw
        Should -Invoke Remove-FirmwareEntry -ParameterFilter { $Number -eq 2 } -Times 1
        Should -Invoke Remove-PartitionAt -Times 1
    }
    It 'logs the one it could not remove' {
        $script:logged = @()
        Mock Write-Log { $script:logged += $Message }
        Invoke-Cleanup
        ($script:logged -join ' ') | Should -BeLike '*Could not remove startup entry Boot0001*firmware says no*'
    }
}

Describe 'Room on the EFI partition' {
    It 'counts the loader usbless is about to replace, and an older name for it' {
        $root = New-Folder "$TestDrive\esp1"
        New-Folder "$root\EFI\usbless\sub" | Out-Null
        New-Folder "$root\EFI\linuxusbless" | Out-Null
        New-Folder "$root\EFI\other" | Out-Null
        [IO.File]::WriteAllBytes("$root\EFI\usbless\sub\a.efi", (New-Object byte[] 100))
        [IO.File]::WriteAllBytes("$root\EFI\linuxusbless\b.efi", (New-Object byte[] 20))
        [IO.File]::WriteAllBytes("$root\EFI\other\c.efi", (New-Object byte[] 999))
        Get-OwnLoaderBytes $root | Should -Be 120
    }
    It 'is nothing when there is none' {
        Get-OwnLoaderBytes (New-Folder "$TestDrive\esp2") | Should -Be 0
    }
    It 'does not say too full because of it' {
        $source = New-Folder "$TestDrive\esp3"
        Set-Content -LiteralPath "$source\BOOTX64.EFI" -Value 'usbless'
        $root = [IO.Path]::GetPathRoot("$TestDrive")
        $free = ([IO.DriveInfo]$root).AvailableFreeSpace
        $linuxMB = [int]($free / 1MB) + 10
        { Assert-EspRoom $root $source $linuxMB } | Should -Throw '*too full*'
        Mock Get-OwnLoaderBytes { [int64]100MB }
        { Assert-EspRoom $root $source $linuxMB } | Should -Not -Throw
    }
}

Describe 'A disk with no partitions' {
    BeforeEach {
        # What Windows does: an error, unless told not to mind.
        Mock Get-Partition {
            if ($PesterBoundParameters.ErrorAction -ne 'SilentlyContinue') { throw 'No MSFT_Partition objects found' }
        } -ParameterFilter { $null -ne $DiskNumber }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-WindowsEsp { [pscustomobject]@{ Guid = '{esp}' } }
        Mock Get-Disk { [pscustomobject]@{ Number = 1; Guid = '{d}' } }
        Mock Read-State { }
        Mock Get-BootEntries { }
        Mock Get-StateDisk { 1 }
    }
    It 'finds no other Linux there' { Find-OtherSystem 1 | Should -BeNullOrEmpty }
    It 'lists no partition IDs' { @(Get-DiskGuids @(1)) | Should -Be @('{esp}') }
    It 'finds nothing recorded there' {
        @(Get-RecordedPartitions ([pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'root'; Offset = 1; Size = 1 }) }) @('root')).Count | Should -Be 0
    }
    It 'sees no Linux installed there' {
        Mock Get-LinuxLoaders { }
        Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @(); LinuxBefore = @(); Partitions = @() }) | Should -BeFalse
    }
    It 'finds nothing at an offset' { Get-PartitionAt 1 ([int64]1GB) | Should -BeNullOrEmpty }
    It 'still opens when looking for another Linux fails' {
        Mock Get-InstallStatus { 'none' }
        Mock Test-System { }
        Mock Get-SpaceInfo { throw 'not measured' }
        Mock Get-Volume { [pscustomobject]@{ Size = 1; SizeRemaining = 1 } }
        Mock Get-DriveTargets { }
        Mock Get-DownloadDrives { }
        Mock Get-RoomPhase { }
        Mock Read-RoomState { }
        Mock Get-OtherSystem { throw 'broken' }
        Mock Test-SecureBoot { $true }
        Mock Get-BootMenuKey { 'F12' }
        (Get-StartupInfo).Other | Should -BeNullOrEmpty
    }
}

Describe 'Limits on moving files' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3 } }
        Mock Get-SupportedSize { }
        $script:logged = @()
        Mock Write-Log { $script:logged += $Message }
    }
    It 'shares one limit across its tries' {
        $DefragLimitSeconds = 2
        Mock Start-DefragRun { [Threading.Thread]::Sleep(2100); 1223 }
        Invoke-Defrag 'C:'
        Should -Invoke Start-DefragRun -Times 1
    }
    It 'gives each try only what is left' {
        $script:given = @()
        Mock Start-DefragRun { $script:given += $Seconds; 1223 }
        Invoke-Defrag 'C:'
        $script:given | ForEach-Object { $_ | Should -BeLessOrEqual $DefragLimitSeconds }
    }
    It 'says nothing moved when every try was cancelled' {
        Mock Start-DefragRun { 1223 }
        Invoke-Defrag 'C:'
        ($script:logged -join ' ') | Should -BeLike '*so nothing moved*'
    }
    It 'does not say so when one worked' {
        $script:codes = [Collections.Queue]::new(@(1223, 0))
        Mock Start-DefragRun { $script:codes.Dequeue() }
        Invoke-Defrag 'C:'
        ($script:logged -join ' ') | Should -Not -BeLike '*so nothing moved*'
    }
    It 'asks the size through the watchdog, and stops asking once the time is up' {
        $DefragLimitSeconds = 0
        Mock Start-DefragRun { 0 }
        Mock Get-SupportedSize { throw 'took too long' }
        Invoke-Defrag 'C:'
        Should -Invoke Get-SupportedSize -Times 1
    }
    It 'tries the size again while there is time' {
        Mock Start-DefragRun { 0 }
        Mock Get-SupportedSize { throw 'not yet' }
        Invoke-Defrag 'C:'
        Should -Invoke Get-SupportedSize -Times 6
    }
    It 'goes through the watchdog when looking for what blocks a shrink' {
        Mock Get-WinEvent { }
        Get-ShrinkBlocker ([pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3 }) | Should -BeNullOrEmpty
        Should -Invoke Get-SupportedSize -Times 1
    }
}

Describe 'diskpart' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Remove-Partition { throw 'protected' }
        $script:piped = @()
        Mock Invoke-Diskpart { $script:piped = $Commands; 'its output' }
        $script:looks = 0
        $partition = [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 2; Guid = '{esp}' }
    }
    It 'gets its commands on its input, with no file' {
        Mock Get-Partition { if ($script:looks++ -eq 0) { $partition } }
        Mock Set-Content { throw 'no files' }
        Mock New-TemporaryFile { throw 'no files' }
        Remove-PartitionByGuid '{esp}' 1
        $script:piped | Should -Be @('select disk 1', 'select partition 2', 'delete partition override', 'exit')
    }
    It 'reports failure when the partition is still there, whatever its exit code says' {
        Mock Get-Partition { $partition }
        { Remove-PartitionByGuid '{esp}' 1 } | Should -Throw '*Could not delete partition 2*'
    }
}

Describe 'The real diskpart' {
    It 'reads commands from its input, here only listing disks' -Skip:(-not $elevated) {
        Invoke-Diskpart @('list disk', 'exit') | Should -Match 'Disk 0'
    }
}

Describe 'What a crash leaves' {
    BeforeEach {
        $script:saved = @()
        Mock Save-State { $script:saved += ($State | ConvertTo-Json -Depth 5) }
        Mock Set-Status { }
        Mock Format-NewPartition { }
        Mock Remove-DriveLetter { }
        Mock Resize-Partition { }
        $state = [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false }
        $plan = [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 3; Shrink = $true; NewWindowsSize = [int64]100GB; TargetSize = [int64]200GB; Letter = 'C'; FreeStart = [int64]150GB; LinuxGB = 40
            InstallerOffset = [int64]146GB; InstallerSize = [int64]4GB; LiveOffset = [int64]150GB; LiveSize = [int64]0
        }
    }
    It 'writes down each partition before making it' {
        Mock New-Partition {
            ($script:saved[-1] | ConvertFrom-Json).Partitions | Where-Object { [int64]$_.Offset -eq $Offset } | Should -Not -BeNullOrEmpty
            [pscustomobject]@{ Offset = $Offset; Size = $Size }
        }
        [void](New-LinuxSpace $plan 'prepared' $state)
        Should -Invoke New-Partition -Times 3
        @($state.Partitions).Role | Should -Be @('boot', 'root', 'installer')
    }
    It 'keeps what Windows really made, if it differs from the plan' {
        Mock New-Partition { [pscustomobject]@{ Offset = $Offset + 1MB; Size = $Size - 1MB } }
        [void](New-LinuxSpace $plan 'freespace' $state)
        [int64]$state.Partitions[0].Offset | Should -Be ([int64]146GB + 1MB)
        [int64]$state.Partitions[0].Size | Should -Be ([int64]4GB - 1MB)
    }
    It 'writes down the size before shrinking' {
        Mock New-Partition { [pscustomobject]@{ Offset = $Offset; Size = $Size } }
        Mock Resize-Partition { [int64]($script:saved[-1] | ConvertFrom-Json).SizeBeforeShrink | Should -Be ([int64]200GB) }
        [void](New-LinuxSpace $plan 'freespace' $state)
        Should -Invoke Resize-Partition -Times 1
    }
    Context 'Undo after it' {
        BeforeEach {
            Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false; SizeBeforeShrink = [int64]200GB; FastStartupWasOn = $false; BitLockerPaused = $false } }
            Mock Unregister-RunAfterRestart { }
            Mock Get-BcdEntries { }
            Mock Get-FirmwareEntries { }
            Mock Use-Esp { }
            Mock Get-UsblessPartitions { }
            Mock Get-RecordedPartitions { }
            Mock Test-LinuxInstalled { $false }
            Mock Get-SpaceOwner { [pscustomobject]@{ Windows = $true } }
            Mock Get-SupportedSize { [pscustomobject]@{ SizeMax = [int64]300GB } }
            Mock Test-Path { $false } -ParameterFilter { $Path -in @($StatePath, $LegacyStatePath) }
        }
        It 'gives the space back when the drive did shrink' {
            Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Size = [int64]100GB } }
            Invoke-Cleanup
            Should -Invoke Resize-Partition -Times 1
        }
        It 'leaves free space that was already there when it did not' {
            Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Size = [int64]200GB } }
            Invoke-Cleanup
            Should -Invoke Resize-Partition -Times 0
        }
    }
}

Describe 'The copy''s progress' {
    BeforeEach {
        Mock Set-ByteProgress { }
        $script:looks = 0
    }
    It 'carries on when progress can''t be read' {
        Mock Start-Process { [Diagnostics.Process]::Start('cmd.exe', '/c ping -n 3 127.0.0.1 >nul') }
        Mock Get-Volume { if ($script:looks++ -gt 0) { throw 'not now' } else { [pscustomobject]@{ SizeRemaining = [int64]1GB } } }
        { Invoke-CopyWatched @('a') 'H' ([int64]1GB) 'the installer' } | Should -Not -Throw
    }
    It 'stops the copy when it is stopped itself' {
        Mock Start-Process { $script:copy = [Diagnostics.Process]::Start('ping.exe', '-n 120 127.0.0.1'); $script:copy }
        Mock Get-Volume { [pscustomobject]@{ SizeRemaining = [int64]1GB } }
        Mock Start-Sleep { throw 'stopped' }
        { Invoke-CopyWatched @('a') 'H' ([int64]1GB) 'the installer' } | Should -Throw 'stopped'
        $script:copy.HasExited | Should -BeTrue
    }
    It 'still reports a copy that failed' {
        Mock Start-Process { [Diagnostics.Process]::Start('cmd.exe', '/c exit 9') }
        Mock Get-Volume { [pscustomobject]@{ SizeRemaining = [int64]1GB } }
        { Invoke-CopyWatched @('a') 'H' ([int64]1GB) 'the installer' } | Should -Throw '*robocopy code 9*'
    }
}

Describe 'A restart that fails' {
    BeforeEach {
        Mock Set-InstallerForNextStart { }
        Mock Clear-BootOnce { }
    }
    It 'forgets the one-time start, and says why' {
        Mock Invoke-Shutdown { throw 'Windows could not restart' }
        { Restart-IntoInstaller } | Should -Throw '*could not restart*'
        Should -Invoke Clear-BootOnce -Times 1
    }
    It 'does the same on the way to the BIOS settings' {
        Mock Invoke-Shutdown { throw 'no' }
        { Restart-IntoFirmware } | Should -Throw 'no'
        Should -Invoke Clear-BootOnce -Times 1
    }
    It 'reports the restart, even if forgetting fails too' {
        Mock Invoke-Shutdown { throw 'no restart' }
        Mock Clear-BootOnce { throw 'no firmware' }
        { Restart-IntoInstaller } | Should -Throw 'no restart'
    }
    It 'leaves it set when the restart goes ahead' {
        Mock Invoke-Shutdown { }
        Restart-IntoInstaller
        Should -Invoke Clear-BootOnce -Times 0
    }
}

Describe 'The lock on running usbless' {
    It 'lets administrators and SYSTEM open it, whichever of them made it' -Skip:(-not $elevated) {
        $method = [Usbless.StateFolder].Assembly.GetType('Usbless.Program').GetMethod('OpenInstanceLock', [Reflection.BindingFlags]'NonPublic,Static')
        $arguments = @($false)
        $lock = $method.Invoke($null, $arguments)
        try {
            $rules = @($lock.GetAccessControl().GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.MutexRights -eq 'FullControl' })
            @($rules.IdentityReference.Value | Sort-Object) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544'
        } finally { $lock.Dispose() }
    }
}

Describe 'Make room''s steps' {
    BeforeEach { Mock Test-PagingFileOn { $true } }
    It 'are the same words for C:' {
        Mock Test-EnoughMemoryWithoutPaging { $true }
        $steps = Get-MakeRoomSteps ''
        $steps.Restart | Should -BeTrue
        $steps.Steps | Should -Be @(
            "On drive $env:SystemDrive turns off **hibernation** and clears the **change journal**."
            "On drive $env:SystemDrive turns off the **paging file**."
            'Restarts this PC, opens again, and moves what''s left out of the way.'
            'Turns everything back on once Linux has its space, or when you close usbless.')
        $steps.Notes | Should -Be @('Save your work first. Your files aren''t touched.')
    }
    It 'leave out the paging file on C: with little memory, and still restart' {
        Mock Test-EnoughMemoryWithoutPaging { $false }
        $steps = Get-MakeRoomSteps ''
        $steps.Restart | Should -BeTrue
        $steps.Steps.Count | Should -Be 3
        $steps.Steps[1] | Should -BeLike 'Restarts*'
    }
    It 'need no restart for another drive with no paging file' {
        Mock Test-EnoughMemoryWithoutPaging { $true }
        Mock Test-PagingFileOn { $false }
        $steps = Get-MakeRoomSteps 'Y'
        $steps.Restart | Should -BeFalse
        $steps.Steps | Should -Be @(
            'On drive Y: clears the **change journal**.'
            'Moves files out of the way, for up to 15 minutes.'
            'Turns everything back on once Linux has its space, or when you close usbless.')
        $steps.Notes | Should -Be @('Your files aren''t touched, and this PC doesn''t restart.')
    }
    It 'restart for another drive with a paging file' {
        Mock Test-EnoughMemoryWithoutPaging { $true }
        $steps = Get-MakeRoomSteps 'Y'
        $steps.Restart | Should -BeTrue
        $steps.Steps[1] | Should -Be 'On drive Y: turns off the **paging file**.'
    }
}

Describe 'Saying when Make room gave up' {
    BeforeEach { $script:RoomPath = Join-Path $TestDrive 'room.json' }

    It 'says nothing when it did not' {
        Get-RoomGaveUpWarning | Should -BeNullOrEmpty
    }
    It 'names what stayed off, once' {
        Set-Content -LiteralPath "$RoomPath.gave-up" 'hibernation'
        Get-RoomGaveUpWarning | Should -Match "couldn't turn hibernation back on"
        Get-RoomGaveUpWarning | Should -BeNullOrEmpty
    }
}

Describe 'A restart Windows refused' {
    It 'forgets the one-time start and that it restarted' {
        Mock Invoke-Shutdown { throw 'no' }
        Mock Clear-BootOnce { }
        Mock Read-State { [pscustomobject]@{ RestartedAt = '2026-01-01T00:00:00' } }
        Mock Save-State { }
        { Invoke-InstallerRestart '/r' } | Should -Throw 'no'
        Should -Invoke Clear-BootOnce -Times 1
        Should -Invoke Save-State -Times 1 -ParameterFilter { $null -eq $State.RestartedAt }
    }
}
