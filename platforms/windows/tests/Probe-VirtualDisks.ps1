<#
    Runs usbless's real disk code against real partitions on throwaway virtual disks. It is not a
    Pester test because it changes disks, so it's named to stay out of Invoke-Pester's way.
    Only run it on a disposable Windows machine, as administrator, after a build:

        powershell -File tests\Probe-VirtualDisks.ps1

    usbless refuses virtual disks by design, and this doesn't change that. The refusal is checked
    first, then this script hides the real disks and reports its own as NVMe with an alias
    called Get-Disk, which wins over the cmdlet in this process alone. It also stands in
    for what can't run here: the firmware, the EFI partition and restarting. Nothing in the
    app can reach any of this. What's left is the real engine: every Storage cmdlet, robocopy,
    format, shrink, undo and defrag.
#>
param(
    [string]$Folder = (Join-Path $env:TEMP 'usbless-probe'),
    [int]$CommandLimitSeconds = 180
)

$root = Split-Path $PSScriptRoot -Parent
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'probe' })
. (Join-Path $root 'engine\Common.ps1')
foreach ($module in Get-ChildItem (Join-Path $root 'engine\*.ps1') | Where-Object Name -ne 'Common.ps1') { . $module.FullName }
[void][Reflection.Assembly]::LoadFrom((Join-Path $root 'bin\Release\usbless.exe'))
$ErrorActionPreference = 'Stop'
$DefragLimitSeconds = 90
$Sync.Gate = New-Object Usbless.CancelGate

$script:Failures = New-Object Collections.ArrayList
$script:Passes = 0
$script:VDisks = @{}          # file name -> VHD path
$script:Pretend = $true       # virtual disks say they're NVMe, and the real disks are hidden

function Check([string]$What, [bool]$Ok, $Detail) {
    if ($Ok) { $script:Passes++; Write-Output "  pass  $What" }
    else { [void]$script:Failures.Add($What); Write-Output "  FAIL  $What  ($Detail)" }
}
function Step([string]$Text) { Write-Output ''; Write-Output "=== $Text  [$((Get-Date).ToString('HH:mm:ss'))]" }

# Every external program here gets a limit, so nothing can sit waiting for ever.
function Invoke-Limited([string]$File, [string[]]$Arguments, [int]$Seconds = $CommandLimitSeconds) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    $null = $process.Handle
    if (-not $process.WaitForExit($Seconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "$File $Arguments was still running after $Seconds seconds."
    }
    $process.ExitCode
}

function Invoke-Diskpart([string[]]$Lines) {
    $script = Join-Path $Folder "diskpart-$([guid]::NewGuid()).txt"
    Set-Content -LiteralPath $script -Encoding ASCII -Value $Lines
    $code = Invoke-Limited 'diskpart.exe' @('/s', "`"$script`"")
    Remove-Item -LiteralPath $script -Force
    if ($code -ne 0) { throw "diskpart failed ($code): $($Lines -join ' / ')" }
}

function Get-RealVDisk([string]$Path) { Get-DiskImage -ImagePath $Path | Storage\Get-Disk }

function New-VDisk([string]$Name, [int]$SizeGB, [string]$Style = 'GPT') {
    $path = Join-Path $Folder "$Name.vhdx"
    Invoke-Diskpart @("create vdisk file=`"$path`" maximum=$($SizeGB * 1024) type=expandable", "select vdisk file=`"$path`"", 'attach vdisk')
    $script:VDisks[$Name] = $path
    $disk = Get-RealVDisk $path
    if ($Style -ne 'RAW') { Initialize-Disk -Number $disk.Number -PartitionStyle $Style }
    Get-RealVDisk $path
}

function Dismount-VDisk([string]$Name) { Dismount-DiskImage -ImagePath $script:VDisks[$Name] | Out-Null }
function Mount-VDisk([string]$Name) { Mount-DiskImage -ImagePath $script:VDisks[$Name] -Access ReadWrite | Out-Null }

# The one change to what the engine sees of the PC. A copy, because a note added to a disk
# object doesn't survive, and an alias, because a function doesn't reliably beat the cmdlet.
function Get-ProbeDisk {
    param($Number)
    $numbers = @($script:VDisks.Values | ForEach-Object { try { (Get-RealVDisk $_).Number } catch { } })
    $all = if ($null -ne $Number) { Storage\Get-Disk -Number $Number } else { Storage\Get-Disk }
    foreach ($disk in $all) {
        if (-not $script:Pretend) { $disk; continue }
        if ($numbers -notcontains $disk.Number) { continue }
        $disk | Select-Object -Property * -ExcludeProperty BusType | Add-Member -NotePropertyName BusType -NotePropertyValue 'NVMe' -PassThru
    }
}
Set-Alias -Name Get-Disk -Value Get-ProbeDisk -Scope Global

# Firmware, restarting and the EFI partition, none of which can be touched here.
function Test-Uefi { $true }
function Get-DiskAttachment($Disk) { 'internal' }
function Get-FirmwareEntries { @() }
function Get-BcdEntries { @() }
function Assert-FirmwareAccess { }
function Assert-SecureBootAllows($Distro) { }
function Get-SecureBootProblem([string]$Root) { }
function Test-SecureBoot { $false }
function Use-Esp([scriptblock]$Action) { }
function Register-Installer([string]$Name) { 7 }
function Test-BitLockerOn { $false }
function Get-FastStartup { 0 }
function Disable-FastStartup { }
function Restore-FastStartup { }
function Invoke-Shutdown([string[]]$Arguments) { throw 'The probe does not restart.' }
function Get-WindowsEsp { throw 'No EFI partition in the probe.' }

function Add-TestFiles([string]$Letter, [int]$Count = 8, [int]$SizeMB = 64) {
    $random = New-Object Random 42
    $buffer = New-Object byte[] (1MB)
    $folder = "$Letter`:\usbless-probe-data"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    for ($i = 0; $i -lt $Count; $i++) {
        $stream = [IO.File]::Create("$folder\file$i.bin")
        for ($mb = 0; $mb -lt $SizeMB; $mb++) { $random.NextBytes($buffer); $stream.Write($buffer, 0, $buffer.Length) }
        $stream.Dispose()
    }
}
function Get-TestHash([string]$Letter) {
    (Get-ChildItem "$Letter`:\usbless-probe-data" -File | Sort-Object Name | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash }) -join ','
}
function Get-Layout($DiskNumber) {
    (Storage\Get-Partition -DiskNumber $DiskNumber | Sort-Object Offset | ForEach-Object { '{0}+{1}' -f $_.Offset, $_.Size }) -join ' '
}

function New-ProbeVolume([int]$Disk, [int64]$Size, [string]$Label, [string]$Format = 'NTFS', [string]$Type) {
    $settings = @{ DiskNumber = $Disk; Size = $Size; AssignDriveLetter = $true }
    if ($Type) { $settings.GptType = $Type; $settings.Remove('AssignDriveLetter') }
    $partition = New-Partition @settings
    if ($Format) { Format-Volume -Partition $partition -FileSystem $Format -NewFileSystemLabel $Label -Confirm:$false -Force | Out-Null }
    Storage\Get-Partition -DiskNumber $Disk -PartitionNumber $partition.PartitionNumber
}

# A small ISO with what Read-Iso checks for. It's real, and really mounted and copied from.
function New-FakeIso([string]$Path) {
    $tree = Join-Path $Folder 'iso-tree'
    New-Item -ItemType Directory -Path "$tree\EFI\BOOT", "$tree\.disk", "$tree\casper", "$tree\boot\grub" -Force | Out-Null
    [IO.File]::WriteAllBytes("$tree\EFI\BOOT\BOOTX64.EFI", (New-Object byte[] 4096))
    Set-Content "$tree\.disk\info" 'Fake Ubuntu'
    $bytes = New-Object byte[] (20MB)
    (New-Object Random 7).NextBytes($bytes)
    [IO.File]::WriteAllBytes("$tree\casper\filesystem.squashfs", $bytes)
    [IO.File]::WriteAllBytes("$tree\casper\vmlinuz", (New-Object byte[] 4096))
    Set-Content "$tree\boot\grub\grub.cfg" @('menuentry "Try" {', '    linux  /casper/vmlinuz  --- quiet', '}', 'menuentry "Arch" {', '    linux  /casper/vmlinuz archisobasedir=arch archisosearchuuid=2026', '}')
    New-Item -ItemType Directory -Path "$tree\arch\x86_64" -Force | Out-Null
    [IO.File]::WriteAllBytes("$tree\arch\x86_64\airootfs.sfs", $bytes)
    Set-Content "$tree\arch\x86_64\airootfs.sha512" 'fake'
    Add-Type -TypeDefinition @'
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class UsblessProbeIso {
    public static void Save(object image, string path) {
        var stream = (IStream)image;
        var buffer = new byte[1048576];
        var read = System.Runtime.InteropServices.Marshal.AllocHGlobal(4);
        using (var file = File.Create(path)) {
            while (true) {
                stream.Read(buffer, buffer.Length, read);
                int count = System.Runtime.InteropServices.Marshal.ReadInt32(read);
                if (count == 0) break;
                file.Write(buffer, 0, count);
            }
        }
    }
}
'@
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3   # ISO 9660 and Joliet, as a real one has
    $image.VolumeName = 'FAKE'
    $image.Root.AddTree($tree, $false)
    [UsblessProbeIso]::Save($image.CreateResultImage().ImageStream, $Path)
}

function Reset-Run {
    foreach ($path in @($StatePath, $LinuxDisksPath, $RoomPath)) { if (Test-Path $path) { Remove-Item -LiteralPath $path -Force } }
    $Sync.Gate = New-Object Usbless.CancelGate
}

# Something the probe makes itself look like Linux usbless put there, which it isn't.
function Remove-LinuxDiskIfAny([string]$Guid) { Set-LinuxDisks (@(Get-LinuxDisks) | Where-Object { $_ -ne $Guid }) }

function Find-Row([string]$Letter) { @(Get-DriveTargets) | Where-Object Letter -eq $Letter | Select-Object -First 1 }

New-Item -ItemType Directory -Path $Folder -Force | Out-Null
Start-Transcript -Path (Join-Path $Folder 'probe.log') -Force | Out-Null
$started = Get-Date

try {
    Step 'Create the disks'
    $iso = Join-Path $Folder 'fake.iso'
    New-FakeIso $iso
    Check 'made a real ISO' (Test-Path $iso) ''

    # The "Windows disk": [ESP][W: pretends to be C:][D: data][recovery][E: data]
    $vdiskA = New-VDisk 'windows' 70
    $a = $vdiskA.Number
    New-ProbeVolume $a 100MB '' '' $EspType | Out-Null
    $w = New-ProbeVolume $a 26GB 'PRETENDC'
    $d = New-ProbeVolume $a 18GB 'DATA'
    $recovery = New-ProbeVolume $a 1GB '' '' $RecoveryType
    $e = New-ProbeVolume $a 5GB 'AFTER'
    $wLetter = [string]$w.DriveLetter; $dLetter = [string]$d.DriveLetter; $eLetter = [string]$e.DriveLetter
    Add-TestFiles $dLetter
    Add-TestFiles $eLetter 2 32
    $dHash = Get-TestHash $dLetter
    $eHash = Get-TestHash $eLetter

    # The second disk: [X: data][free space][Y: exFAT, which usbless can't shrink][free space]
    $vdiskB = New-VDisk 'second' 80
    $b = $vdiskB.Number
    $x = New-ProbeVolume $b 20GB 'SECOND'
    $xLetter = [string]$x.DriveLetter
    Add-TestFiles $xLetter
    $xHash = Get-TestHash $xLetter

    function Get-WindowsPartition { Storage\Get-Partition -DiskNumber (Get-RealVDisk $script:VDisks['windows']).Number | Where-Object { [int64]$_.Offset -eq [int64]$w.Offset } }
    $env:SystemDrive = "$wLetter`:"

    Check 'the stand-in for Get-Disk is what the engine gets' ((Get-Command Get-Disk).CommandType -eq 'Alias' -and @(Get-Disk).Count -eq 2 -and @(Get-Disk)[0].BusType -eq 'NVMe') ''

    Step 'usbless refuses these disks when nothing pretends'
    $script:Pretend = $false
    $real = Storage\Get-Disk -Number $b
    Write-Output "  bus type of the virtual disk: $($real.BusType), number $($real.Number), GUID $($real.Guid)"
    Check 'a real VHD is refused as virtual' ((Get-DriveBlocker $real $null) -like '*virtual*') (Get-DriveBlocker $real $null)
    $vdiskRaw = New-VDisk 'raw' 20 'RAW'
    Check 'a real uninitialised VHD is called not set up' ((Get-DriveBlocker (Get-RealVDisk $script:VDisks['raw']) $null) -like "*isn't set up*") ''
    $vdiskMbr = New-VDisk 'mbr' 20 'MBR'
    Check 'a real MBR VHD is refused' ((Get-DriveBlocker (Get-RealVDisk $script:VDisks['mbr']) $null) -like '*MBR*') ''
    $script:Pretend = $true

    Step 'Viability on real partitions'
    $rows = @(Get-DriveTargets)
    foreach ($row in $rows) { Write-Output ('  {0,-14} {1,-7} usable {2,4} GB tail {3,4} GB  {4}' -f $row.Title, $row.Kind, $row.UsableGB, $row.TailFreeGB, $row.Blocker) }
    Check 'the RAW and MBR disks get a row with a reason' (@($rows | Where-Object { $_.Kind -eq 'disk' -and $_.Blocker }).Count -eq 2) ''
    Check 'pretend C: is listed as C:' (($rows | Where-Object Id -eq '').Letter -eq $wLetter) ''
    Check 'the recovery partition is not offered' (-not ($rows | Where-Object { $_.Id -match [int64]$recovery.Offset })) ''
    Check 'real recovery partition is refused by name' ((Get-DriveBlocker (Get-Disk -Number $a) $recovery) -like '*recovery partition*') ''
    Check 'D: is offered' (-not (Find-Row $dLetter).Blocker) ''
    Check 'second disk volume is offered' (-not (Find-Row $xLetter).Blocker) ''
    Check 'second disk free space is folded into its volume' ((Find-Row $xLetter).TailFreeGB -ge 50) ''

    $y = New-ProbeVolume $b 6GB 'NOTNTFS' 'exFAT'
    Check 'a real exFAT volume is refused and named' ((Find-Row ([string]$y.DriveLetter)).Blocker -like '*uses exFAT*') ((Find-Row ([string]$y.DriveLetter)).Blocker)
    $gapRow = @(Get-DriveTargets) | Where-Object { $_.Kind -eq 'gap' -and $_.DiskName } | Select-Object -First 1
    Check 'free space after a refused volume is offered on its own' ($null -ne $gapRow) ''
    Write-Output "  free space row: $($gapRow.Id) $($gapRow.UsableGB) GB"
    Remove-PartitionAt $b $y.Offset

    Step 'Real shrink limit, from the bounded query'
    $space = Get-SpaceInfo "volume:$($vdiskA.Guid):$([int64]$d.Offset)"
    Write-Output "  D: min $([int64]$space.MinSize) usable $($space.UsableGB) GB"
    Check 'the query returned a real limit' ($space.MinSize -gt 0 -and $space.MinSize -lt $d.Size) $space.MinSize
    $measured = Get-DriveSpace "volume:$($vdiskA.Guid):$([int64]$d.Offset)"
    Check 'the row is measured once chosen' (-not $measured.Estimated -and $measured.UsableGB -eq $space.UsableGB) ''

    Step 'Download lands on the chosen drive'
    $source = Join-Path $Folder 'source.iso'
    [IO.File]::WriteAllBytes($source, (New-Object byte[] (2MB)))
    $folderOnD = Get-DownloadFolder $dLetter
    Check 'the folder is on that drive' ($folderOnD -eq "$dLetter`:\usbless") $folderOnD
    $hash = (Get-FileHash $source -Algorithm SHA256).Hash
    $download = New-Download ('file:///' + ($source -replace '\\', '/')) $hash 0
    Get-Iso $download (Join-Path $folderOnD $download.FileName)
    Check 'curl really saved it there and the checksum matched' (Test-Path (Join-Path $folderOnD $download.FileName)) ''
    Check 'nothing partial is left' (-not (Test-Path (Join-Path $folderOnD "$($download.FileName).part"))) ''
    Remove-Item $folderOnD -Recurse -Force
    Check 'lists real drives for the download' (@(Get-DownloadDrives | Where-Object Letter -eq $dLetter).Count -eq 1) ''
    try { Assert-DownloadRoom "$eLetter`:\huge.iso" ([int64]500GB) 0; Check 'refuses a download that does not fit' $false '' }
    catch { Check 'refuses a download that does not fit and offers another drive' ($_.Exception.Message -like '*another drive*') $_.Exception.Message }

    Step 'A: same disk, second volume, shrink, freespace install, undo'
    Reset-Run
    $beforeA = Get-Layout $a
    $target = "volume:$($vdiskA.Guid):$([int64]$d.Offset)"
    Invoke-Install 'ubuntu' $iso 6 $target ''
    $state = Read-State
    $afterD = Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -eq [int64]$d.Offset }
    $installer = @(Get-UsblessPartitions) | Where-Object { $_.Label -eq $InstallerLabel }
    Write-Output "  layout now: $(Get-Layout $a)"
    Check 'D: keeps its offset and has shrunk' ($afterD -and $afterD.Size -lt $d.Size) $afterD.Size
    Check 'D: shrank by what Linux and the installer need' ([int64]$d.Size - [int64]$afterD.Size -eq ([int64]6GB + [int64]4GB)) ([int64]$d.Size - [int64]$afterD.Size)
    Check 'the installer sits straight after D:' ([int64]$installer.Partition.Offset -eq [int64]$afterD.Offset + [int64]$afterD.Size) ''
    $next = Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -gt [int64]$installer.Partition.Offset } | Sort-Object { [int64]$_.Offset } | Select-Object -First 1
    Check 'exactly the space for Linux is left after the installer' ([int64]$next.Offset - ([int64]$installer.Partition.Offset + [int64]$installer.Partition.Size) -eq 6GB) $next.Offset
    Check 'data on D: survived the shrink' ((Get-TestHash $dLetter) -eq $dHash) ''
    Check 'the partition after it did not move' ((Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -eq [int64]$e.Offset }).Size -eq $e.Size) ''
    Check 'the installer holds the real files' (Test-Path "$($installer.Letter):\casper\filesystem.squashfs") ''
    Check 'and the hidden folder a live system needs' (Test-Path "$($installer.Letter):\.disk\info") ''
    Check 'state says where it went' ($state.TargetLetter -eq $dLetter -and $state.DiskGuid -eq $vdiskA.Guid -and [int64]$state.TargetOffset -eq [int64]$d.Offset -and $state.OnWindowsDisk -eq $true -and $state.WindowsShrunk -eq $true) ($state | ConvertTo-Json -Compress)
    Check 'status is ready' ((Get-InstallStatus) -eq 'ready') (Get-InstallStatus)
    Check 'Linux not thought installed' (-not (Test-LinuxInstalled $state)) ''
    Write-Output "  alongside finds it: $($state.AlongsideOk)"
    $steps = Get-Steps (Get-Distro 'ubuntu' '') 6 $state
    Write-Output ($steps.Steps -join "`n  ")
    Invoke-Cleanup
    Check 'undo: the layout is back exactly' ((Get-Layout $a) -eq $beforeA) "$(Get-Layout $a) vs $beforeA"
    Check 'undo: data on D: survived' ((Get-TestHash $dLetter) -eq $dHash) ''
    Check 'undo: data on the drive after it survived' ((Get-TestHash $eLetter) -eq $eHash) ''
    Check 'undo: status is none' ((Get-InstallStatus) -eq 'none') (Get-InstallStatus)

    Step 'A0: Omarchy: a second partition for what FAT32 cannot hold, then undo'
    Reset-Run
    $beforeLive = Get-Layout $a
    $omarchy = Get-Distro 'omarchy' ''
    $target = "volume:$($vdiskA.Guid):$([int64]$d.Offset)"
    $isoInfo = Read-Iso $iso $omarchy
    Check 'its big file is kept off FAT32' ($isoInfo.LiveGB -eq 1 -and @($isoInfo.LiveFiles).Count -eq 2) $isoInfo.LiveGB
    $plan = Get-Plan 6 $isoInfo.InstallerGB $target $isoInfo.LiveGB
    $liveState = [pscustomobject]@{ Partitions = @(); DiskGuid = $vdiskA.Guid; DiskNumber = $plan.DiskNumber; WindowsShrunk = $false; TargetKind = $plan.Kind; TargetOffset = $plan.TargetOffset; TargetLetter = $plan.Letter; OnWindowsDisk = $true; InstallerNextToWindows = $true; FastStartupWasOn = $false; BitLockerPaused = $false }
    Save-State $liveState
    $installerPartition = New-LinuxSpace $plan 'freespace' $liveState | Select-Object -Last 1
    $letter = Get-DriveLetter $installerPartition
    Copy-Installer $isoInfo $letter
    $live = Get-PartitionAt $plan.DiskNumber $plan.LiveOffset
    $liveLetter = Get-DriveLetter $live
    Copy-LiveFiles $isoInfo $liveLetter
    Check 'the second partition is exFAT, with its label' ((Get-Volume -DriveLetter $liveLetter).FileSystemType -eq 'exFAT' -and (Get-Volume -DriveLetter $liveLetter).FileSystemLabel -eq $LiveLabel) ''
    Check 'the big file is on it, whole' ((Get-FileHash "$liveLetter`:\arch\x86_64\airootfs.sfs").Hash -eq (Get-FileHash "$($isoInfo.Letter):\arch\x86_64\airootfs.sfs").Hash) ''
    Check 'and not on the installer partition' (-not (Test-Path "$letter`:\arch\x86_64\airootfs.sfs")) ''
    Check 'the rest is on the installer partition' (Test-Path "$letter`:\EFI\BOOT\BOOTX64.EFI") ''
    Update-BootConfig $omarchy "$letter`:\"
    Update-BootConfig $omarchy "$letter`:\"
    $menu = Get-Content "$letter`:\boot\grub\grub.cfg" -Raw
    Check 'the menu names the second partition, once' (([regex]::Matches($menu, "archisolabel=$LiveLabel ")).Count -eq 1 -and ([regex]::Matches($menu, 'systemd\.run=')).Count -eq 1) $menu
    Remove-DriveLetter $live
    Check 'usbless can tell both are its own, with no letter on the second' (@(Get-UsblessPartitions | Where-Object { $_.Label -in $InstallerLabel, $LiveLabel }).Count -eq 2) ''
    Remove-Item -LiteralPath $StatePath -Force
    Check 'still, with no state file' (@(Get-UsblessPartitions | Where-Object { $_.Label -in $InstallerLabel, $LiveLabel }).Count -eq 2) ''
    Save-State $liveState
    Dismount-DiskImage -ImagePath $iso | Out-Null
    Invoke-Cleanup
    Check 'undo: the layout is back exactly' ((Get-Layout $a) -eq $beforeLive) "$(Get-Layout $a) vs $beforeLive"
    Check 'undo: data on D: survived' ((Get-TestHash $dLetter) -eq $dHash) ''

    Step 'A1: replacing Windows: only the installer, a menu that asks for memory, undo'
    Reset-Run
    function Get-WindowsEsp { Storage\Get-Partition -DiskNumber $a | Where-Object GptType -eq $EspType | Select-Object -First 1 }
    Invoke-Install 'ubuntu' $iso 60 $target '' -FullDisk
    $state = Read-State
    $afterD = Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -eq [int64]$d.Offset }
    $installer = @(Get-UsblessPartitions) | Where-Object { $_.Label -eq $InstallerLabel }
    Write-Output "  layout now: $(Get-Layout $a)"
    Check 'D: shrank by the installer and no more' ([int64]$d.Size - [int64]$afterD.Size -eq [int64]4GB) ([int64]$d.Size - [int64]$afterD.Size)
    Check 'the state says what this is' ($state.FullDisk -eq $true -and $state.LinuxGB -eq 0) ($state | ConvertTo-Json -Compress)
    Check 'only the installer is usbless''s' (@(Get-UsblessPartitions).Count -eq 1) @(Get-UsblessPartitions).Count
    Check 'the menu on the partition asks for the copy to memory' ((Get-Content "$($installer.Letter):\boot\grub\grub.cfg" -Raw) -match '/casper/vmlinuz toram nopersistent\s+--- quiet') (Get-Content "$($installer.Letter):\boot\grub\grub.cfg" -Raw)
    Check 'the steps say to erase, and name the disk' (((Get-StateSteps).Steps -join ' ') -like "*Erase disk and install*$($state.DiskName) ($($state.DiskGB) GB)*") ((Get-StateSteps).Steps -join ' ')
    Check 'status is ready, like any other' ((Get-InstallStatus) -eq 'ready') (Get-InstallStatus)
    Invoke-Cleanup
    Check 'undo: the layout is back exactly' ((Get-Layout $a) -eq $beforeA) "$(Get-Layout $a) vs $beforeA"
    Check 'undo: data on D: survived' ((Get-TestHash $dLetter) -eq $dHash) ''
    Check 'undo: status is none' ((Get-InstallStatus) -eq 'none') (Get-InstallStatus)
    Reset-Run
    $refused = $false
    try { Invoke-Install 'lubuntu' $iso 60 $target '' -FullDisk } catch { $refused = $_.Exception.Message -like "*hasn't shown*" }
    Check 'a system not shown to work is refused' $refused ''
    Check 'and the disk was not touched' ((Get-Layout $a) -eq $beforeA) (Get-Layout $a)
    function Get-WindowsEsp { throw 'No EFI partition in the probe.' }

    Step 'A2: same disk, second volume, prepared system, undo'
    Reset-Run
    Invoke-Install 'elementary' $iso 6 $target ''
    $labels = (@(Get-UsblessPartitions).Label | Sort-Object) -join ','
    Check 'all three partitions are found by label' ($labels -eq "$InstallerLabel,$BootLabel,$RootLabel") $labels
    Check 'the Linux partitions have no letter' (@(Get-UsblessPartitions | Where-Object { $_.Label -ne $InstallerLabel -and $_.Letter }).Count -eq 0) ''
    Invoke-Cleanup
    Check 'undo: layout is back' ((Get-Layout $a) -eq $beforeA) (Get-Layout $a)
    Check 'undo: data survived' ((Get-TestHash $dLetter) -eq $dHash) ''

    Step 'A3: Linux installed: installer goes, its space goes to D:, Linux stays'
    Reset-Run
    Invoke-Install 'elementary' $iso 6 $target ''
    $shrunk = Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -eq [int64]$d.Offset }
    $root_ = @(Get-UsblessPartitions) | Where-Object Label -eq $RootLabel
    Invoke-Cleanup -InstallerOnly
    $after = Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -eq [int64]$d.Offset }
    Check 'D: gets the installer''s space' ([int64]$after.Size -eq [int64]$shrunk.Size + 4GB) "$($after.Size) vs $($shrunk.Size)"
    Check 'the Linux partition is still there' ($null -ne (Storage\Get-Partition -DiskNumber $a | Where-Object { [int64]$_.Offset -eq [int64]$root_.Partition.Offset })) ''
    foreach ($left in @(Get-UsblessPartitions)) { Remove-PartitionAt $left.Partition.DiskNumber $left.Partition.Offset }
    Resize-Partition -DiskNumber $a -PartitionNumber $after.PartitionNumber -Size ([int64]$d.Size)
    Check 'put back for the next run' ((Get-Layout $a) -eq $beforeA) (Get-Layout $a)

    Step 'A4: pretend C:, old state file with none of the new fields, undo finds C:'
    Reset-Run
    $beforeOld = Get-Layout $a
    $free = Get-DiskGaps (Get-Disk -Number $a) @(Storage\Get-Partition -DiskNumber $a)
    Write-Output "  free on the Windows disk: $(@($free).Count) gaps"
    Invoke-Install 'ubuntu' $iso 1 '' ''
    $state = Read-State
    $old = [pscustomobject]@{}
    foreach ($name in 'Distro', 'DistroId', 'Strategy', 'LinuxGB', 'DiskNumber', 'WindowsShrunk', 'Partitions', 'BootNumber', 'IsoPath', 'Created', 'Copied', 'RestartedAt', 'LoadersBefore', 'LinuxBefore', 'FastStartupWasOn', 'BitLockerPaused', 'InstallerNextToWindows') {
        $old | Add-Member -NotePropertyName $name -NotePropertyValue $state.$name
    }
    Save-State $old
    Check 'the old file reads as ready' ((Get-InstallStatus) -eq 'ready') (Get-InstallStatus)
    Check 'steps read as they did' (((Get-Steps (Get-Distro 'ubuntu' '') 1 (Read-State)).Steps -join ' ') -like '*alongside*') ''
    Invoke-Cleanup
    Check 'undo gives C: its space back' ((Get-Layout $a) -eq $beforeOld) "$(Get-Layout $a) vs $beforeOld"

    Step 'B: second disk, free space after a volume, nothing shrinks'
    Reset-Run
    $beforeB = Get-Layout $b
    $target = "volume:$($vdiskB.Guid):$([int64]$x.Offset)"
    $vhdWindowsLayout = Get-Layout $a
    Invoke-Install 'ubuntu' $iso 6 $target ''
    $state = Read-State
    $afterX = Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }
    Check 'X: did not shrink' ([int64]$afterX.Size -eq [int64]$x.Size) $afterX.Size
    Check 'the Windows disk was not touched' ((Get-Layout $a) -eq $vhdWindowsLayout) ''
    Check 'state says second disk' ($state.OnWindowsDisk -eq $false -and $state.DiskGuid -eq $vdiskB.Guid -and $state.WindowsShrunk -eq $false) ($state | ConvertTo-Json -Compress)
    Check 'the installer is on the second disk' ((@(Get-UsblessPartitions) | Where-Object Label -eq $InstallerLabel).Partition.DiskNumber -eq $b) ''
    Check 'status is ready' ((Get-InstallStatus) -eq 'ready') (Get-InstallStatus)
    $text = (Get-StateSteps | ForEach-Object { $_.Steps + $_.Notes }) -join "`n  "
    Write-Output "  steps:`n  $text"
    Check 'steps go to manual and name the disk' ($text -like '*Manual installation*Msft Virtual Disk*' -and $text -notmatch 'alongside') ''

    Step 'B2: the disk number changes between restarts'
    $xPathsBefore = $xLetter
    Dismount-VDisk 'second'
    Check 'with the disk gone, the setup is a leftover' ((Get-InstallStatus) -eq 'leftover') (Get-InstallStatus)
    Check 'and usbless can tell the disk is missing' ($null -eq (Get-StateDisk (Read-State))) ''
    # Another disk arriving first takes its number, as can happen at any restart.
    New-VDisk 'shift' 5 | Out-Null
    Mount-VDisk 'second'
    Start-Sleep -Seconds 3
    $moved = (Get-RealVDisk $script:VDisks['second']).Number
    Write-Output "  second disk was $b, now $moved"
    Check 'it really moved' ($moved -ne $b) $moved
    Check 'found by GUID afterwards' ((Get-StateDisk (Read-State)) -eq $moved) ''
    Check 'status is ready again' ((Get-InstallStatus) -eq 'ready') (Get-InstallStatus)
    Invoke-Cleanup
    Check 'undo works on the new number' ((Get-Layout $moved) -eq $beforeB) "$(Get-Layout $moved) vs $beforeB"
    # Reattaching can hand out a different letter.
    $xLetter = [string](Storage\Get-Partition -DiskNumber $moved | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }).DriveLetter
    Write-Output "  X: was $xPathsBefore, now $xLetter"
    Check 'data on X: survived' ((Get-TestHash $xLetter) -eq $xHash) ''
    $b = $moved

    Step 'B3: second disk, must shrink X:, undo gives it back'
    Reset-Run
    # Use up the free space with a volume, so the only way is to shrink X:.
    $x = Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }
    $tail = Get-TailFree $x
    $filler = New-Partition -DiskNumber $b -Offset ([int64]$x.Offset + [int64]$x.Size) -Size ([int64]([math]::Floor($tail / 1MB) * 1MB))
    $withFiller = Get-Layout $b
    $target = "volume:$($vdiskB.Guid):$([int64]$x.Offset)"
    Invoke-Install 'ubuntu' $iso 6 $target ''
    $afterX = Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }
    Check 'X: shrank by exactly what was needed' ([int64]$x.Size - [int64]$afterX.Size -eq [int64]10GB) ([int64]$x.Size - [int64]$afterX.Size)
    Check 'data on X: survived the shrink' ((Get-TestHash $xLetter) -eq $xHash) ''
    Check 'Linux disk reads as second disk' ((Read-State).OnWindowsDisk -eq $false) ''
    Invoke-Cleanup
    Check 'undo: X: is back to its size and the filler untouched' ((Get-Layout $b) -eq $withFiller) "$(Get-Layout $b) vs $withFiller"
    Check 'undo: data survived' ((Get-TestHash $xLetter) -eq $xHash) ''

    Step 'B4: crash: state file lost, clean-up works from the labels on the second disk'
    Reset-Run
    Invoke-Install 'elementary' $iso 6 $target ''
    Remove-Item -LiteralPath $StatePath -Force
    Check 'status is leftover from labels alone' ((Get-InstallStatus) -eq 'leftover') (Get-InstallStatus)
    Invoke-Cleanup
    Check 'undo: X: gets its space back by neighbour' ((Get-Layout $b) -eq $withFiller) "$(Get-Layout $b) vs $withFiller"
    Check 'undo: data survived' ((Get-TestHash $xLetter) -eq $xHash) ''
    Check 'status is none' ((Get-InstallStatus) -eq 'none') (Get-InstallStatus)

    Step 'B5: a failure half way puts everything back'
    Reset-Run
    $copyInstaller = ${function:Copy-Installer}
    function Copy-Installer($Iso, [string]$Target) { throw 'Simulated failure while copying.' }
    $threw = $false
    try { Invoke-Install 'ubuntu' $iso 6 $target '' } catch { $threw = $_.Exception.Message -like '*Simulated*' }
    Check 'the failure reached the caller' $threw ''
    Check 'undo: layout is back' ((Get-Layout $b) -eq $withFiller) (Get-Layout $b)
    Check 'state is gone' (-not (Test-Path $StatePath)) ''
    ${function:Copy-Installer} = $copyInstaller

    Step 'B6: a partition usbless recorded but never formatted is found on the second disk'
    Remove-PartitionAt $b $filler.Offset
    Reset-Run
    $raw = New-Partition -DiskNumber $b -Offset ([int64]$x.Offset + [int64]$x.Size + 1GB) -Size ([int64]2GB)
    $half = [pscustomobject]@{
        Partitions = @([pscustomobject]@{ Role = 'installer'; Offset = [int64]$raw.Offset; Size = [int64]$raw.Size })
        DiskGuid = $vdiskB.Guid; TargetKind = 'volume'; TargetOffset = [int64]$x.Offset; WindowsShrunk = $false; OnWindowsDisk = $false; LoadersBefore = @(); LinuxBefore = @()
    }
    Save-State $half
    Check 'it is recognised' (@(Get-RecordedPartitions (Read-State) @('installer')).Count -eq 1) ''
    Invoke-Cleanup
    Check 'and removed' ($null -eq (Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$raw.Offset })) ''

    Step 'B7: free space with no volume to grow, prepared system'
    Reset-Run
    $y = New-ProbeVolume $b 6GB 'NOTNTFS' 'exFAT'
    $gapRow = @(Get-DriveTargets) | Where-Object { $_.Kind -eq 'gap' -and $_.Id -like "gap:$($vdiskB.Guid)*" } | Sort-Object UsableGB -Descending | Select-Object -First 1
    Check 'the second disk''s free space is offered' ($null -ne $gapRow) ''
    $beforeGap = Get-Layout $b
    Invoke-Install 'elementary' $iso 6 $gapRow.Id ''
    $state = Read-State
    Check 'it is recorded as free space' ($state.TargetKind -eq 'gap' -and $state.InstallerNextToWindows -eq $false) ($state | ConvertTo-Json -Compress)
    Write-Output "  layout: $(Get-Layout $b)"
    $linuxEnd = (@(Storage\Get-Partition -DiskNumber $b) | Measure-Object -Property Offset -Maximum).Maximum
    $boot = @(Get-UsblessPartitions) | Where-Object Label -eq $BootLabel
    $inst = @(Get-UsblessPartitions) | Where-Object Label -eq $InstallerLabel
    Check 'USBLBOOT is on the second disk' ($boot.Partition.DiskNumber -eq $b) ''
    Check 'the installer sits straight before it' ([int64]$inst.Partition.Offset + [int64]$inst.Partition.Size -eq [int64]$boot.Partition.Offset) ''
    Invoke-Cleanup
    Check 'undo: the disk is as it was' ((Get-Layout $b) -eq $beforeGap) "$(Get-Layout $b) vs $beforeGap"
    Check 'nothing grew' ((Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }).Size -eq $x.Size) ''
    Remove-PartitionAt $b $y.Offset

    Step 'B8: someone''s own drive that happens to be called USBLBOOT is safe'
    Reset-Run
    $mine = New-ProbeVolume $b 2GB $BootLabel
    Add-TestFiles ([string]$mine.DriveLetter) 1 8
    Check 'not counted as usbless''s' (@(Get-UsblessPartitions | Where-Object { [int64]$_.Partition.Offset -eq [int64]$mine.Offset }).Count -eq 0) ''
    Invoke-Cleanup
    Check 'not removed by a clean-up' ($null -ne (Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$mine.Offset })) ''
    Remove-PartitionAt $b $mine.Offset

    Step 'B9: Linux installed on the second disk, then removed'
    Reset-Run
    $beforeLinux = Get-Layout $b
    Invoke-Install 'ubuntu' $iso 6 $target ''
    $state = Read-State
    $inst = @(Get-UsblessPartitions) | Where-Object Label -eq $InstallerLabel
    # What a Linux installer leaves: a Linux partition in the space usbless set aside.
    $linuxPart = New-Partition -DiskNumber $b -Offset ([int64]$inst.Partition.Offset + [int64]$inst.Partition.Size) -Size 5GB -GptType '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
    Check 'usbless sees Linux on the second disk' (Test-LinuxInstalled $state) ''
    Check 'status is installed' ((Get-InstallStatus) -eq 'installed') (Get-InstallStatus)
    Check 'Linux on this disk is not offered before it has been kept' ($null -eq (Get-OtherSystem)) ''
    Invoke-Cleanup
    Check 'clean-up noticed and only took the installer' ($null -ne (Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$linuxPart.Offset })) ''
    Check 'the installer is gone' (@(Get-UsblessPartitions).Count -eq 0) ''
    Check 'X: never gave anything up, so it keeps its size' ((Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }).Size -eq $x.Size) ''
    Check 'the disk is remembered' (@(Get-LinuxDisks) -contains $vdiskB.Guid) (@(Get-LinuxDisks) -join ',')
    $other = Get-OtherSystem
    Check 'and that Linux is now offered for removal' ($null -ne $other -and -not $other.OnWindowsDisk) ''
    Check 'the disk is refused while it has Linux on it' ((Get-DriveBlocker (Get-Disk -Number $b) $null) -like '*already has Linux*') ''
    Remove-OtherSystem
    Check 'removing it gives the disk back as it was' ((Get-Layout $b) -eq $beforeLinux) "$(Get-Layout $b) vs $beforeLinux"
    Check 'and forgets the disk' (@(Get-LinuxDisks).Count -eq 0) ''
    Check 'data survived' ((Get-TestHash $xLetter) -eq $xHash) ''

    Step 'B10: the partition casper makes when an older build started the installer'
    Reset-Run
    $beforeCasper = Get-Layout $b
    Invoke-Install 'ubuntu' $iso 6 $target ''
    $state = Read-State
    $inst = @(Get-UsblessPartitions) | Where-Object Label -eq $InstallerLabel
    $menu = Get-Content "$($inst.Letter):\boot\grub\grub.cfg" -Raw
    Check 'the copied menu tells casper not to' ($menu -match '/casper/vmlinuz nopersistent\s+---') $menu
    $state.RestartedAt = (Get-Date).ToString('s')
    Save-State $state
    # Where casper-helpers puts it: the first multiple of 4096 sectors after the last partition, to the end of the disk.
    $unit = [int64]4096 * (Storage\Get-Disk -Number $b).LogicalSectorSize
    $last = @(Storage\Get-Partition -DiskNumber $b | Sort-Object { [int64]$_.Offset + [int64]$_.Size })[-1]
    $start = [int64]([math]::Ceiling(([int64]$last.Offset + [int64]$last.Size) / $unit)) * $unit
    $casper = New-Partition -DiskNumber $b -Offset $start -UseMaximumSize -GptType $LinuxPartitionTypes[0]
    Write-Output "  layout: $(Get-Layout $b)"
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class UsblessProbeRaw {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    public static void Write(int disk, long offset, byte[] data) {
        var handle = CreateFileW(@"\\.\PhysicalDrive" + disk, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        using (var stream = new FileStream(handle, FileAccess.ReadWrite, 1, false)) { stream.Position = offset; stream.Write(data, 0, data.Length); stream.Flush(); }
    }
}
'@
    # The superblock fields usbless reads, at the offsets ext4 has them. QEMU's run showed "writable" at 1144.
    function New-ExtBytes([string]$Label) {
        $bytes = New-Object byte[] 4096
        [BitConverter]::GetBytes([uint32]1000).CopyTo($bytes, 1024)
        $bytes[1080] = 0x53; $bytes[1081] = 0xEF
        [Text.Encoding]::ASCII.GetBytes($Label).CopyTo($bytes, 1144)
        , $bytes
    }
    # An earlier step's file system may still be here, as old data is on a used disk, where this wouldn't count as empty.
    [UsblessProbeRaw]::Write($b, $start, (New-Object byte[] (128KB)))
    Check 'usbless ties an empty one to this setup, as casper leaves when its mkfs fails' ((Get-CasperPartition (Read-State) @(Storage\Get-Partition -DiskNumber $b)).Guid -eq $casper.Guid) ''
    [UsblessProbeRaw]::Write($b, $start, (New-ExtBytes 'mydata'))
    Check 'one holding another name is not' ($null -eq (Get-CasperPartition (Read-State) @(Storage\Get-Partition -DiskNumber $b))) ''
    Check 'and counts as Linux, as it always has' (Test-LinuxInstalled (Read-State)) ''
    [UsblessProbeRaw]::Write($b, $start, (New-ExtBytes 'writable'))
    Check 'the signature is read from the disk' ((Get-PartitionSignature $casper) -eq 'ext') (Get-PartitionSignature $casper)
    Check 'usbless ties a writable one to this setup' ((Get-CasperPartition (Read-State) @(Storage\Get-Partition -DiskNumber $b)).Guid -eq $casper.Guid) ''
    Check 'and does not say Linux is installed' (-not (Test-LinuxInstalled (Read-State))) ''
    Check 'status is still ready' ((Get-InstallStatus) -eq 'ready') (Get-InstallStatus)
    Check 'and it is not offered as another Linux' ($null -eq (Get-OtherSystem)) ''
    $notOurs = Read-State
    $notOurs.LinuxBefore = @($casper.Guid)
    Check 'one from before this setup is left alone' ($null -eq (Get-CasperPartition $notOurs @(Storage\Get-Partition -DiskNumber $b))) ''
    Invoke-Cleanup
    Check 'undo removes it, and the disk is as it was' ((Get-Layout $b) -eq $beforeCasper) "$(Get-Layout $b) vs $beforeCasper"
    Check 'data survived' ((Get-TestHash $xLetter) -eq $xHash) ''

    Step 'B11: a partition called writable that usbless did not cause'
    Reset-Run
    Invoke-Install 'ubuntu' $iso 6 $target ''
    $state = Read-State
    $last = @(Storage\Get-Partition -DiskNumber $b | Sort-Object { [int64]$_.Offset + [int64]$_.Size })[-1]
    $start = [int64]([math]::Ceiling(([int64]$last.Offset + [int64]$last.Size) / $unit)) * $unit
    $theirs = New-Partition -DiskNumber $b -Offset $start -UseMaximumSize -GptType $LinuxPartitionTypes[0]
    [UsblessProbeRaw]::Write($b, $start, (New-ExtBytes 'writable'))
    # usbless never started the installer, so nothing of usbless's can have made it.
    Check 'not tied before a restart' ($null -eq (Get-CasperPartition $state @(Storage\Get-Partition -DiskNumber $b))) ''
    Invoke-Cleanup
    Check 'undo leaves it' ($null -ne (Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq $start })) ''
    Remove-PartitionAt $b $start
    Remove-LinuxDiskIfAny $vdiskB.Guid

    Step 'C: Make room on a data drive, for real and with a limit'
    Reset-Run
    & fsutil.exe usn createjournal m=0x1000000 a=0x100000 "$dLetter`:" | Out-Null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = Start-MakeRoom $dLetter
    $clock.Stop()
    Write-Output "  result $result in $([int]$clock.Elapsed.TotalSeconds) seconds, with a limit of $DefragLimitSeconds"
    Check 'no restart was needed' ($result -eq 'done') $result
    Check 'stayed inside its limit' ($clock.Elapsed.TotalSeconds -lt $DefragLimitSeconds + 60) $clock.Elapsed.TotalSeconds
    Check 'the phase is ready' ((Read-RoomState).Phase -eq 'ready') ''
    Check 'data survived' ((Get-TestHash $dLetter) -eq $dHash) ''
    & fsutil.exe usn queryjournal "$dLetter`:" 2>&1 | Out-Null
    Check 'the journal is gone while room is being made' ($LASTEXITCODE -ne 0) $LASTEXITCODE
    Restore-RoomSettings
    & fsutil.exe usn queryjournal "$dLetter`:" 2>&1 | Out-Null
    Check 'and comes back afterwards' ($LASTEXITCODE -eq 0) $LASTEXITCODE
    Check 'the file is gone' (-not (Test-Path $RoomPath)) ''
    Write-Output "  what defrag said: $(@($Sync.Log | Where-Object { $_ -like '*moving files*' }) | Select-Object -Last 1)"
    # Files have to be scattered to give defrag something to do, and even then it can finish first.
    # With a second to run, it either stops at the limit or was quick enough not to reach it. Either way usbless moves on.
    $DefragLimitSeconds = 1
    $took = Measure-Command { Invoke-Defrag $dLetter }
    $DefragLimitSeconds = 90
    Check 'a limit stops defrag and moves on' ($took.TotalSeconds -lt 60) $took.TotalSeconds
    Write-Output "  what the limit did: $(@($Sync.Log) | Select-Object -Last 2)"
    Check 'with no defrag left running' (@(Get-Process defrag -ErrorAction SilentlyContinue).Count -eq 0) ''

    Step 'D: Expand a drive into its free space'
    $tailBefore = Get-TailFree (Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset })
    Expand-Windows "volume:$($vdiskB.Guid):$([int64]$x.Offset)"
    $grown = Storage\Get-Partition -DiskNumber $b | Where-Object { [int64]$_.Offset -eq [int64]$x.Offset }
    Check 'X: grew into it' ([int64]$grown.Size -gt [int64]$x.Size) "$($grown.Size), tail was $tailBefore"
    Check 'data survived' ((Get-TestHash $xLetter) -eq $xHash) ''
} catch {
    [void]$script:Failures.Add("Stopped: $($_.Exception.Message) at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)")
    Write-Output "STOPPED: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
} finally {
    $script:Pretend = $false
    foreach ($name in @($script:VDisks.Keys)) { try { Dismount-VDisk $name } catch { Write-Output "Could not detach $name`: $($_.Exception.Message)" } }
    Write-Output ''
    Write-Output "=== $script:Passes passed, $($script:Failures.Count) failed, in $([int]((Get-Date) - $started).TotalMinutes) minutes"
    foreach ($failure in $script:Failures) { Write-Output "  FAILED: $failure" }
    Stop-Transcript | Out-Null
}
if ($script:Failures.Count) { exit 1 }
