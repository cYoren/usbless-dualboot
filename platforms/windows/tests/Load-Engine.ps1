# What every test file starts with. Dot-source it from BeforeAll, with -WithUsbless for usbless.exe's C# types,
# which need a build first. Mocks stay in each file, because they differ.
param([switch]$WithUsbless)

$root = Split-Path $PSScriptRoot -Parent
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'test' })
. (Join-Path $root 'engine\Common.ps1')
foreach ($module in Get-ChildItem (Join-Path $root 'engine\*.ps1') | Where-Object Name -ne 'Common.ps1') { . $module.FullName }
# Add-Type refuses .exe files.
if ($WithUsbless) { [void][Reflection.Assembly]::LoadFrom((Join-Path $root 'bin\Release\usbless.exe')) }
