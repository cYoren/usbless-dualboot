@echo off
rem Test infrastructure only. Never run on an ordinary physical machine.
rem findstr.exe is absent from current Windows installation media. Use builtins.
set "LAB_MANUFACTURER="
set "LAB_PRODUCT="
for /f "tokens=2,*" %%a in ('reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS /v SystemManufacturer 2^>nul') do if "%%b"=="USBlessLab" set "LAB_MANUFACTURER=1"
for /f "tokens=2,*" %%a in ('reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS /v SystemProductName 2^>nul') do if "%%b"=="DisposableVM" set "LAB_PRODUCT=1"
if not defined LAB_MANUFACTURER exit /b 91
if not defined LAB_PRODUCT exit /b 92
if exist "%~d0\layout-complete.marker" exit /b 0
rem Keep the removable seed's drive letter. Setup assigns the installed OS C:
rem after reboot; trying to assign C: here conflicts with the seed in WinPE.
(
echo select disk 0
echo detail disk
echo clean
echo convert gpt
echo create partition efi size=512
echo format quick fs=fat32 label=USBDBLABEFI
echo create partition msr size=16
echo create partition primary
echo format quick fs=ntfs label=USBDBLABWIN
echo exit
) >X:\usbless-layout.txt
diskpart.exe /s X:\usbless-layout.txt >"%~d0\layout.log" 2>&1
if errorlevel 1 exit /b %errorlevel%
echo USBless disposable disk initialized>"%~d0\layout-complete.marker"
exit /b %errorlevel%
