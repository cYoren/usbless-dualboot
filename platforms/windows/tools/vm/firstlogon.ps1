# Runs once, elevated, the first time the test VM signs in. Makes the VM quiet and able to be driven,
# then shuts it down so the disk can be compressed and cached. UAC, hibernation, the paging file and
# Fast Startup stay as Windows set them, because that's what usbless is being tested against.
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\probe-setup.log

New-Item -ItemType Directory -Path C:\probe -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'boot.ps1') -Destination C:\probe\boot.ps1 -Force
Add-MpPreference -ExclusionPath C:\probe -ErrorAction SilentlyContinue

# Stays signed in across restarts, which the logon count in the answer file wouldn't do.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon AutoAdminLogon '1'
Set-ItemProperty $winlogon DefaultUserName 'usbless'
Set-ItemProperty $winlogon DefaultPassword 'usbless-probe-1'
Remove-ItemProperty $winlogon AutoLogonCount -ErrorAction SilentlyContinue

# No screen lock, sleep or updates to get in the way of a test.
$personal = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
New-Item $personal -Force | Out-Null
Set-ItemProperty $personal NoLockScreen 1 -Type DWord
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
$update = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item $update -Force | Out-Null
Set-ItemProperty $update NoAutoUpdate 1 -Type DWord
Set-Service wuauserv -StartupType Disabled
$cloud = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
New-Item $cloud -Force | Out-Null
Set-ItemProperty $cloud DisableWindowsConsumerFeatures 1 -Type DWord
Set-ItemProperty $cloud DisableSoftLanding 1 -Type DWord

# Two ways in, both of which only run what the host running this VM sends: one in the signed-in
# session, elevated, for looking at usbless's windows, and one as SYSTEM in case that session is stuck.
$user = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\probe\boot.ps1 user'
$system = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\probe\boot.ps1 system'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'usbless probe user' -Action $user -Settings $settings -Force `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User usbless) `
    -Principal (New-ScheduledTaskPrincipal -UserId usbless -LogonType Interactive -RunLevel Highest) | Out-Null
Register-ScheduledTask -TaskName 'usbless probe system' -Action $system -Settings $settings -Force `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest) | Out-Null

# Smaller to cache: what's free reads back as nothing.
Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Optimize-Volume -DriveLetter C -ReTrim

Stop-Transcript
shutdown.exe /s /t 5 /c "Test VM set up"
