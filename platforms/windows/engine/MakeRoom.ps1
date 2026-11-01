# --- Make room ------------------------------------------------------------
# A drive can only shrink down to the last file Windows can't move, however much is free. usbless
# clears what usually sits there, restarts, moves what's left, and puts it all back once
# Linux has its space. What it changed is saved first, so a crash can't leave it that way.
#
# C: is the usual case. Another drive never has hibernation's file on it, and only has a paging
# file if someone moved it there, so most of the time it doesn't need a restart at all. Each
# function takes a drive letter, and without one means C:.

$RoomPath = Join-Path $StateDir 'make-room.json'
$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'   # builds before the tasks used this
$ResumeTaskName = 'usbless resume'
$RestoreTaskName = 'usbless restore settings'
$RestoreArgument = '--restore-room'
$PagingKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$MinMemoryWithoutPaging = 8GB
$DefragLimitSeconds = 900
$DefragTries = 4
$DefragRetrySeconds = 30
$DefragCancelled = 1223
$RoomRestoreTries = 8   # the task tries every 15 minutes, and each time usbless opens or closes

# Windows logs the file that limits a shrink whenever it works out the limit, so ask and read it.
function Get-ShrinkBlocker($Partition) {
    $c = if ($Partition) { $Partition } else { Get-WindowsPartition }
    $since = (Get-Date).AddSeconds(-5)
    try { [void](Get-SupportedSize $c) } catch { }
    for ($i = 0; $i -lt 3; $i++) {
        $found = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag'; Id = 259; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($found) { return Get-BlockerFile $found.Message }
        Start-Sleep -Seconds 1
    }
}

# The message is translated, so this looks for the path rather than the words around it.
function Get-BlockerFile([string]$Message) {
    # An ordinary file comes with its default stream's name, \pagefile.sys::$DATA, which means nothing to anyone.
    if ($Message -match ':\s*(\\(?!\\)[^\r\n]+)') { $Matches[1].Trim() -replace '::\$DATA$', '' }
}

function Get-BlockerKind([string]$File) {
    switch -Regex ($File) {
        '^$' { return 'unknown' }
        'hiberfil' { return 'hibernation' }
        'pagefile|swapfile' { return 'paging' }
        'System Volume Information' { return 'restore' }
        'UsnJrnl' { return 'journal' }
        '^\\\$' { return 'ntfs' }
    }
    'file'
}

function Read-RoomState {
    if (-not (Test-Path -LiteralPath $RoomPath)) { return }
    try {
        $state = Get-Content -LiteralPath $RoomPath -Raw | ConvertFrom-Json
        if ($state.Phase) { return $state }
        Write-Log 'Could not read what Make room changed: the file makes no sense.'
    } catch { Write-Log "Could not read what Make room changed: $($_.Exception.Message)" }
}

# It says what the settings were, and nothing else does, so it isn't replaced or removed.
function Test-RoomFileDamaged { (Test-Path -LiteralPath $RoomPath) -and -not (Read-RoomState) }

function Save-RoomState($State) {
    Write-StateFile $RoomPath ($State | ConvertTo-Json -Depth 4)
}

# 'continue' after the restart, 'restore' if something stopped before finishing, or nothing.
# Only the log knew otherwise. Shown once, the next time usbless checks before an install.
function Get-RoomGaveUpWarning {
    $file = "$RoomPath.gave-up"
    if (-not (Test-Path -LiteralPath $file)) { return }
    $what = (Get-Content -LiteralPath $file -Raw).Trim()
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    "**Make room couldn't turn $what back on.** Turn it on again in Windows' settings. Your files aren't affected."
}

function Get-RoomPhase {
    $state = Read-RoomState
    if (-not $state) { return }
    if ($state.Phase -eq 'restarting' -and (Get-LastBoot) -gt [datetime]$state.Saved) { return 'continue' }
    'restore'
}

function Get-LastBoot { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }

# A new Windows only has the default, until something changes it.
function Test-HibernationOn {
    $power = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
    if ($null -ne $power.HibernateEnabled) { return $power.HibernateEnabled -eq 1 }
    $power.HibernateEnabledDefault -eq 1
}

function Set-Hibernation([bool]$On) {
    & powercfg.exe /h $(if ($On) { 'on' } else { 'off' }) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "Could not turn hibernation $(if ($On) { 'on' } else { 'off' })." }
}

function Get-RoomDrive([string]$Letter) { if ($Letter) { "$($Letter.TrimEnd(':')):" } else { $env:SystemDrive } }

function Clear-ChangeJournal([string]$Drive) {
    & fsutil.exe usn deletejournal /d (Get-RoomDrive $Drive) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Could not clear the change journal.' }
}

function New-ChangeJournal([string]$Drive) {
    # Windows' own defaults.
    & fsutil.exe usn createjournal m=0x2000000 a=0x800000 (Get-RoomDrive $Drive) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Could not make a new change journal; Windows makes one itself when it needs it.' }
}

# The registry value Windows reads at startup, because it can be put back exactly. Going through
# Win32_PageFileSetting moved a paging file from D: to C: when it was tested on a real Windows.
function Get-PagingSettings {
    @((Get-ItemProperty $PagingKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles)
}

function Set-PagingSettings([string[]]$Files) {
    New-ItemProperty -Path $PagingKey -Name PagingFiles -PropertyType MultiString -Value ([string[]]@($Files | Where-Object { $_ })) -Force | Out-Null
}

# Paging files on other drives stay: they aren't in the way, and Windows may need one.
# "?:" is Windows choosing the drive itself, which is usually C:, so it only counts for C:.
function Get-PagingWithoutSystemDrive([string[]]$Files, [string]$Drive) {
    $room = Get-RoomDrive $Drive
    $drive_ = [regex]::Escape($room)
    $pattern = if ($room -eq $env:SystemDrive) { "^($drive_|\?:)" } else { "^$drive_" }
    @($Files | Where-Object { $_ -and $_ -notmatch $pattern })
}

function Set-PagingOff([string]$Drive) {
    Set-PagingSettings (Get-PagingWithoutSystemDrive (Get-PagingSettings) $Drive)
}

# Taking it off another drive needs a restart, so only when it's really there.
function Test-PagingFileOn([string]$Drive) {
    $room = [regex]::Escape((Get-RoomDrive $Drive))
    @(Get-PagingSettings | Where-Object { $_ -match "^$room" }).Count -gt 0
}

function Restore-Paging($Saved) {
    Set-PagingSettings @($Saved)
}

function Test-EnoughMemoryWithoutPaging {
    (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory -ge $MinMemoryWithoutPaging
}

function Get-MakeRoomSteps([string]$Drive) {
    $room = Get-RoomDrive $Drive
    $isWindows = $room -eq $env:SystemDrive
    $pagingOff = (Test-EnoughMemoryWithoutPaging) -and ($isWindows -or (Test-PagingFileOn $room))
    $restart = $isWindows -or $pagingOff
    $steps = @(if ($isWindows) { "On drive $room turns off **hibernation** and clears the **change journal**." } else { "On drive $room clears the **change journal**." })
    if ($pagingOff) { $steps += "On drive $room turns off the **paging file**." }
    $steps += if ($restart) { 'Restarts this PC, opens again, and moves what''s left out of the way.' } else { 'Moves files out of the way, for up to 15 minutes.' }
    $steps += 'Turns everything back on once Linux has its space, or when you close usbless.'
    $note = if ($restart) { 'Save your work first. Your files aren''t touched.' } else { 'Your files aren''t touched, and this PC doesn''t restart.' }
    [pscustomobject]@{ Steps = $steps; Restart = $restart; Notes = @($note) }
}

# Says 'restarting' when the PC is on its way down, or 'done' when another drive didn't need it to be.
function Start-MakeRoom([string]$Drive) {
    # An earlier run on another drive saved its settings in the same file. They go back first, so
    # none are lost and what's saved next is what's really there.
    if (Test-RoomFileDamaged) {
        throw "usbless can't read what an earlier Make room turned off, and starting again would lose it. Check hibernation and the paging file are how you want them in Windows' settings, delete $RoomPath and try again."
    }
    if (Read-RoomState) {
        Restore-RoomSettings
        if (Test-Path -LiteralPath $RoomPath) { throw "usbless couldn't turn back on what an earlier Make room turned off, and starting again would lose it. Restart this PC and try again." }
    }
    $room = Get-RoomDrive $Drive
    $isWindows = $room -eq $env:SystemDrive
    $pagingOff = (Test-EnoughMemoryWithoutPaging) -and ($isWindows -or (Test-PagingFileOn $room))
    $state = [pscustomobject]@{
        Phase = 'restarting'; Saved = (Get-Date).ToString('s'); Hibernation = $isWindows -and (Test-HibernationOn)
        Paging = @(Get-PagingSettings); PagingOff = $pagingOff; Drive = $room
    }
    Save-RoomState $state
    try {
        if ($isWindows) {
            Set-Status 'Turning off hibernation...'
            Set-Hibernation $false
        }
        Clear-ChangeJournal $room
        if ($isWindows -or $pagingOff) {
            if ($state.PagingOff) {
                Set-Status 'Turning off the paging file...'
                Set-PagingOff $room
            }
            Request-RoomRestart
            return 'restarting'
        }
        Invoke-Defrag $room
        $state.Phase = 'ready'
        Save-RoomState $state
        'done'
    } catch {
        Write-Log "Failed: $($_.Exception.Message)"
        Restore-RoomSettings
        throw
    }
}

# Windows asks every window before it restarts. RoomRestarting tells usbless's that this restart is its
# own, and to let it go. Something else can still stop the restart, so the window can ask again.
function Request-RoomRestart {
    $Sync.RoomRestarting = $true
    try {
        Register-RunAfterRestart
        Set-Status 'Restarting...'
        Invoke-Shutdown '/r', '/t', '0'
    } catch {
        $Sync.RoomRestarting = $false
        throw
    }
}

# Two tasks, because a prompt at sign-in with No already chosen is a bad way to finish, and someone may
# never come back to usbless at all. One opens usbless when this user signs in, elevated and without asking. The
# other puts the settings back by itself if usbless hasn't, from a while after Windows starts: see Program.cs.
# Both run a copy no ordinary process can replace, with fixed arguments, or they'd be a way around UAC.
# If they can't be made this throws, because restarting without them could strand the settings.
function Register-RunAfterRestart {
    $exe = Get-RestartCopy
    $state = Read-RoomState
    $earlier = @($state.CopyFolder, [Usbless.RestartCopy]::OwnFolder()) | Where-Object { $_ -and $_ -ne (Split-Path $exe -Parent) } | Select-Object -Unique
    if ($state) {
        $state | Add-Member -NotePropertyName CopyFolder -NotePropertyValue (Split-Path $exe -Parent) -Force
        Save-RoomState $state
    }
    Set-RoomTasks $exe
    foreach ($name in @($ResumeTaskName, $RestoreTaskName)) {
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { throw "Windows didn't keep the task called $name." }
    }
    Remove-ItemProperty -Path $RunOnceKey -Name 'usbless' -ErrorAction SilentlyContinue
    # Nothing starts these any more: one from asking to restart before, and the one running, if it's a copy.
    foreach ($folder in @($earlier)) { Remove-RestartCopy $folder }
}

# Always a new one. The one usbless may be running from can already be set to go as Windows next starts,
# which would leave the tasks pointing at nothing, just when they're needed.
function Get-RestartCopy {
    [Usbless.RestartCopy]::Create($ProgramData)
}

function Set-RoomTasks([string]$Exe) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $ResumeTaskName -Force -Settings $settings `
        -Action (New-ScheduledTaskAction -Execute $Exe) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
        -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) | Out-Null
    # While usbless is open it leaves things alone, so it keeps trying until usbless has gone.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT20M'
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)).Repetition
    Register-ScheduledTask -TaskName $RestoreTaskName -Force -Settings $settings `
        -Action (New-ScheduledTaskAction -Execute $Exe -Argument $RestoreArgument) `
        -Trigger $trigger `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) | Out-Null
}

function Remove-RoomTask([string]$Name) {
    try { Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue } catch { Write-Log "Could not remove the task $Name`: $($_.Exception.Message)" }
}

# Once usbless has opened again. The other task stays until the settings are back.
function Unregister-ResumeTask {
    Remove-RoomTask $ResumeTaskName
    Remove-ItemProperty -Path $RunOnceKey -Name 'usbless' -ErrorAction SilentlyContinue
}

function Unregister-RunAfterRestart {
    Unregister-ResumeTask
    Remove-RoomTask $RestoreTaskName
    Remove-RestartCopy (Read-RoomState).CopyFolder
}

# Only the folder usbless made and wrote down, and never through a link someone has put there. Program.cs
# deals with the one usbless is running from, because a running file can't be deleted.
function Remove-RestartCopy([string]$Folder) {
    if (-not $Folder) { return }
    if ($Folder -eq [Usbless.RestartCopy]::OwnFolder()) {
        try { [Usbless.RestartCopy]::RemoveAtNextStart($Folder) } catch { Write-Log "Could not set $Folder to go at the next start: $($_.Exception.Message)" }
        return
    }
    if ((Split-Path $Folder -Parent) -ne $ProgramData -or -not (Split-Path $Folder -Leaf).StartsWith([Usbless.RestartCopy]::FolderPrefix)) { return }
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    try {
        if ((Get-Item -LiteralPath $Folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        [IO.Directory]::Delete($Folder, $true)
    } catch { Write-Log "Could not remove $Folder`: $($_.Exception.Message)" }
}

# What the second task runs, when usbless isn't open. Afterwards there's nothing left for it to do.
function Restore-RoomFromTask {
    Write-Log 'Putting back what Make room changed, because usbless did not.'
    Restore-RoomSettings
    # The file still being there means they aren't all back, so this has to run again.
    if (Test-Path -LiteralPath $RoomPath) {
        Write-Log 'Make room''s settings are not all back. This task tries again later.'
        return
    }
    Remove-RoomTask $ResumeTaskName
    Remove-RoomTask $RestoreTaskName
}

# After the restart: the paging file has gone, so move what can be moved. Says 'done', or 'failed'
# when it couldn't, for example because that drive has been unplugged. That can't be allowed to stop
# usbless opening every time from now on, so the settings go back and usbless carries on without the room.
function Complete-MakeRoom {
    Unregister-ResumeTask
    $state = Read-RoomState
    try { Invoke-Defrag $state.Drive } catch {
        Write-Log "Could not move files on drive $(Get-RoomDrive $state.Drive): $($_.Exception.Message)"
        Restore-RoomSettings
        return 'failed'
    }
    if ($state) {
        $state.Phase = 'ready'
        Save-RoomState $state
    }
    'done'
}

# It can run for a very long time. Whatever it moved before the limit still counts. Says the code it finished with.
function Start-DefragRun([string]$Room, [int]$Seconds = $DefragLimitSeconds) {
    $process = Start-Process defrag.exe -ArgumentList "$Room /X" -WindowStyle Hidden -PassThru
    $null = $process.Handle   # keeps ExitCode readable after the process exits
    try {
        if ($process.WaitForExit($Seconds * 1000)) { return $process.ExitCode }
        Write-Log "Stopped moving files after $Seconds seconds."
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
    }
}

function Invoke-Defrag([string]$Drive) {
    $room = Get-RoomDrive $Drive
    Set-Status 'This can take several minutes. Whatever usbless moves still counts, even if it stops early.'
    # All the tries share one limit: closing usbless is refused meanwhile, and the safety net can't run.
    $deadline = (Get-Date).AddSeconds($DefragLimitSeconds)
    $cancelled = 0
    # Straight after signing in it can give up at once with 1223, having moved nothing, as seen on a real Windows.
    for ($try = 1; $try -le $DefragTries; $try++) {
        $left = [int][math]::Floor(($deadline - (Get-Date)).TotalSeconds)
        if ($left -le 0) { break }
        $code = Start-DefragRun $room $left
        Write-Log "Finished moving files (code $code)."
        if ($code -ne $DefragCancelled) { break }
        $cancelled++
        if ($try -lt $DefragTries) { Start-Sleep -Seconds ([math]::Min($DefragRetrySeconds, $left)) }
    }
    if ($cancelled -eq $DefragTries) { Write-Log "Windows cancelled moving files all $DefragTries times, so nothing moved." }
    # Windows can't work out the limit for a moment after that.
    $c = Get-Partition -DriveLetter $room.TrimEnd(':')
    for ($i = 0; $i -lt 6; $i++) {
        try { [void](Get-SupportedSize $c); break } catch {
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 5
        }
    }
}

function Clear-RestorePoints([string]$Drive) {
    $room = Get-RoomDrive $Drive
    Set-Status "Deleting restore points on drive $room..."
    & vssadmin.exe delete shadows "/for=$room" /all /quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows could not delete the restore points on drive $room." }
    Invoke-Defrag $room
}

# Puts back whatever Make room changed. One failure must not stop the rest. The file and the safety
# net only go once it's all back, in that order, so being stopped part way loses nothing. What didn't
# go back is tried again by the task or the next time usbless opens, a limited number of times, since
# something like a full disk mustn't keep this going for ever.
function Restore-RoomSettings {
    $Sync.RoomRestarting = $false
    $state = Read-RoomState
    if (-not $state) { return }
    $back = @()
    $failed = @()
    if ($state.Hibernation) {
        try { Set-Hibernation $true } catch { Write-Log "Could not turn hibernation back on: $($_.Exception.Message)" }
        if (Test-HibernationOn) { $back += 'hibernation' } else { $failed += 'hibernation' }
    }
    if ($state.PagingOff) {
        try { Restore-Paging $state.Paging; $back += 'the paging file' } catch {
            Write-Log "Could not turn the paging file back on: $($_.Exception.Message)"
            $failed += 'the paging file'
        }
    }
    try { New-ChangeJournal $state.Drive } catch { Write-Log "Could not make a new change journal: $($_.Exception.Message)" }
    if ($back.Count) { Write-Log "Turned $($back -join ' and ') back on." }
    if ($failed.Count) {
        $tries = [int]$state.RestoreTries + 1
        if ($tries -lt $RoomRestoreTries) {
            Write-Log "Could not turn $($failed -join ' and ') back on. usbless will try again ($tries of $RoomRestoreTries)."
            # Not 'restarting', or the next time usbless opens it would carry on with Make room. Only what's left gets tried again.
            $state.Phase = 'restore'
            $state.Hibernation = $failed -contains 'hibernation'
            $state.PagingOff = $failed -contains 'the paging file'
            $state | Add-Member -NotePropertyName RestoreTries -NotePropertyValue $tries -Force
            try { Save-RoomState $state } catch { Write-Log "Could not save that: $($_.Exception.Message)" }
            return
        }
        Write-Log "Gave up turning $($failed -join ' and ') back on after $tries tries. Turn it on in Windows' settings."
        try { Write-StateFile "$RoomPath.gave-up" ($failed -join ' and ') } catch { Write-Log "Could not save that: $($_.Exception.Message)" }
    }
    Unregister-RunAfterRestart
    Remove-Item -LiteralPath $RoomPath -Force -ErrorAction SilentlyContinue
}
