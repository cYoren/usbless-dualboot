"""What gets run on the VM, by name: hopvm.py run screens stuck ...

Each scenario saves a screen at every step. What it prints goes to the job's log. Neither the job nor
a scenario finishing says hop worked: look at the screens and read the log."""
import json
import os
import time

import hopvm
from hopvm import log

HOP = r'C:\Users\hop\Downloads\hop.exe'

# Where hop's window puts things, at 96 DPI, from src/MainForm.cs and src/Sentence.cs.
LINE_ONE_Y, LINE_TWO_Y = 96 + 23, 96 + 46 + 23
# Rows in the drive picker, which opens 8 under the sentence's second line, with 6 of padding.
DRIVE_ROW_Y, DRIVE_ROW_H = 96 + 46 + 49 + 8 + 6 + 21, 42
# The same for the system picker, under the first line.
SYSTEM_ROW_Y = 96 + 49 + 8 + 6 + 21

UI_SCRIPT = r'''
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W { [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r); }
"@
$process = Get-Process hop -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $process) { '{"found":false}'; return }
$root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
$r = New-Object W+R
[void][W]::GetWindowRect($process.MainWindowHandle, [ref]$r)
$controls = foreach ($e in $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
    $c = $e.Current
    if ($c.IsOffscreen -or $c.BoundingRectangle.IsEmpty) { continue }
    @{ name = $c.Name; type = $c.ControlType.ProgrammaticName; enabled = $c.IsEnabled; x = [int]$c.BoundingRectangle.X; y = [int]$c.BoundingRectangle.Y; w = [int]$c.BoundingRectangle.Width; h = [int]$c.BoundingRectangle.Height }
}
@{ found = $true; left = $r.L; top = $r.T; right = $r.Rr; bottom = $r.B; title = $process.MainWindowTitle; controls = @($controls) } | ConvertTo-Json -Depth 4 -Compress
'''

# What Make room is meant to change and put back.
FACTS_SCRIPT = r'''
"--- $(Get-Date -Format s), started $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s'))"
$c = Get-Partition -DriveLetter C
$v = Get-Volume -DriveLetter C
"C: size {0:N1} GB, free {1:N1} GB" -f ($c.Size/1GB), ($v.SizeRemaining/1GB)
$s = Get-PartitionSupportedSize -DriveLetter C
"can shrink to {0:N1} GB, so {1:N1} GB can be released" -f ($s.SizeMin/1GB), (($c.Size-$s.SizeMin)/1GB)
"hibernation: HibernateEnabled=" + (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Power).HibernateEnabled
"HibernateEnabledDefault=" + (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Power).HibernateEnabledDefault
"tasks: " + ((Get-ScheduledTask 'hop *' -ErrorAction SilentlyContinue | Where-Object TaskName -notlike 'hop probe*' | ForEach-Object { "$($_.TaskName) -> $($_.Actions.Execute) $($_.Actions.Arguments)" }) -join ' ; ')
"copies: " + ((Get-ChildItem C:\ProgramData -Directory -Filter 'hop-restart-*' -Force -ErrorAction SilentlyContinue).FullName -join ' ; ')
cmd /c dir /a C:\*.sys | Select-String '\.sys'
"PagingFiles: " + ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles -join ' | ')
"journal: " + ((fsutil usn queryjournal C: 2>&1 | Select-String 'Usn Journal ID|Maximum Size|Allocation Delta|Error') -join ' ; ')
"RunOnce: " + ((Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce -ErrorAction SilentlyContinue).hop)
"make-room.json: " + $(if (Test-Path C:\ProgramData\hop\make-room.json) { Get-Content C:\ProgramData\hop\make-room.json -Raw } else { 'none' })
"state.json: " + $(if (Test-Path C:\ProgramData\hop\state.json) { 'there' } else { 'none' })
Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset | ForEach-Object { "  part {0} {1,-12} offset {2:N2} GB size {3:N2} GB letter [{4}]" -f $_.PartitionNumber, $_.Type, ($_.Offset/1GB), ($_.Size/1GB), $_.DriveLetter }
"hop running: " + ((Get-Process hop -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) '$($_.MainWindowTitle)'" }) -join ', ')
Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Microsoft-Windows-Defrag'; Id=259 } -MaxEvents 1 -ErrorAction SilentlyContinue | ForEach-Object { "last shrink blocker event, $($_.TimeCreated.ToString('s')): " + ($_.Message -replace '\s+',' ') }
'''

# Where hop is running from, and who could change that file.
FROM_WHERE = r'''
$p = Get-Process hop | Select-Object -First 1
"hop running from: " + $p.Path
icacls (Split-Path $p.Path -Parent)
icacls $p.Path
Get-ScheduledTask 'hop *' | Where-Object TaskName -notlike 'hop probe*' | ForEach-Object { "$($_.TaskName) [$($_.State)] -> $($_.Actions.Execute) $($_.Actions.Arguments) as $($_.Principal.UserId) $($_.Principal.RunLevel)" }
'''

LOGS_SCRIPT = r'''
Get-ChildItem C:\ProgramData\hop -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
Get-ChildItem C:\ProgramData\hop\logs -File -ErrorAction SilentlyContinue | ForEach-Object { "=== $($_.Name)"; Get-Content $_.FullName -Tail 150 }
'''


class Session:
    """A running VM, and the things a person at it would do."""

    def __init__(self, vm):
        self.vm = vm

    def facts(self, why=''):
        print(f'===== {why}\n' + self.vm.ps(FACTS_SCRIPT, timeout=400), flush=True)

    def hop_log(self):
        print(self.vm.ps(LOGS_SCRIPT, timeout=60), flush=True)

    def ui(self):
        try:
            return json.loads(self.vm.ps(UI_SCRIPT, timeout=60).strip() or '{"found":false}')
        except ValueError as ex:
            log(f'ui: {ex}')
            return {'found': False}

    def controls(self):
        ui = self.ui()
        return [c for c in ui.get('controls', []) if c.get('name')] if ui.get('found') else []

    def names(self):
        return [c['name'] for c in self.controls()]

    def wait_button(self, name, limit=300):
        end = time.time() + limit
        while time.time() < end:
            for c in self.controls():
                if c['name'] == name:
                    return c
            time.sleep(3)
        self.vm.shot(f'no-{name.replace(" ", "-")}')
        raise TimeoutError(f'no {name} button after {limit} seconds. There are: {self.names()}')

    def press(self, name, limit=300):
        c = self.wait_button(name, limit)
        self.vm.click(c['x'] + c['w'] // 2, c['y'] + c['h'] // 2)

    def click_hop(self, x, y):
        """A place in hop's window, in the numbers src/MainForm.cs uses."""
        ui = self.ui()
        self.vm.click(ui['left'] + x, ui['top'] + y)

    def get_hop(self):
        print(self.vm.ps(f'New-Item -ItemType Directory -Force C:\\Users\\hop\\Downloads | Out-Null; (New-Object Net.WebClient).DownloadFile("http://10.0.2.2:{hopvm.PORT}/file/hop.exe", "{HOP}"); Get-Item {HOP} | Select-Object Length, LastWriteTime | Format-List'), flush=True)

    def open_as_a_person(self, name='elevation-prompt'):
        """Through the shell, not elevated, so Windows asks, and the answer goes in on the keyboard."""
        self.vm.key('esc')    # Windows opens the Start menu on the first sign-in
        time.sleep(1)
        self.vm.ps(f'Start-Process explorer.exe "{HOP}"', timeout=30)
        time.sleep(8)
        self.vm.shot(name)
        self.vm.key('alt', 'y')
        self.wait_window()

    def wait_window(self, limit=180):
        end = time.time() + limit
        while time.time() < end:
            if self.ui().get('found'):
                return True
            time.sleep(3)
        self.vm.shot('no-hop-window')
        raise TimeoutError('no hop window')

    def settle(self, limit=300):
        """Until hop has stopped saying Checking, and shows a button."""
        end = time.time() + limit
        while time.time() < end:
            if any(n in ('Install', 'Make room', 'Close', 'Clean up', 'Restart now', 'Try again', 'Remove the installer') or n.startswith('Use ') for n in self.names()):
                return
            time.sleep(3)
        raise TimeoutError('hop is still working out what to show')

    def desktop(self):
        self.vm.wait_agent('user', limit=900)
        self.vm.shot('desktop')


class Bench:
    """Starts VMs from the image, one at a time."""

    def __init__(self, secure_boot=True):
        self.secure_boot = secure_boot
        self.vm = None

    def fresh(self, second_disk=False):
        """Back to Windows as it was installed, with a new VM."""
        if self.vm:
            self.vm.stop()
            self.vm.server.shutdown()
            self.vm.server.server_close()
        vm = hopvm.Vm(secure_boot=self.secure_boot)
        if second_disk:
            path = os.path.join(hopvm.RUN, 'second.qcow2')
            os.makedirs(hopvm.RUN, exist_ok=True)
            hopvm.run('qemu-img', 'create', '-f', 'qcow2', path, '80G')
            vm.extra_disks.append(path)
        disk, vars_fd, tpm = hopvm.new_run_disks()
        vm.start(disk, vars_fd, tpm)
        self.vm = vm
        return vm, Session(vm)


def main(args):
    bench = Bench(secure_boot=not args.no_secure_boot)
    failed = False
    try:
        for name in args.scenarios:
            log(f'===== scenario {name}')
            try:
                globals()[f'scenario_{name}'](bench)
            except Exception as ex:
                failed = True
                log(f'scenario {name} stopped: {ex!r}')
                try:
                    bench.vm.shot(f'{name}-stopped')
                except Exception:
                    pass
    finally:
        if bench.vm:
            bench.vm.stop()
    raise SystemExit(1 if failed else 0)


# --- Getting Windows into a state ---------------------------------------------------------------


def restart_and_wait(vm, limit=600):
    before = vm.agent_boot.get('user')
    vm.ps('shutdown.exe /r /t 3', timeout=30)
    vm.wait_agent('user', limit=limit, not_boot=before)


def make_second_disk(vm):
    """A GPT disk with an NTFS D: and free space after it, as Disk Management would leave it."""
    print(vm.ps(r"""
$disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
Initialize-Disk -Number $disk.Number -PartitionStyle GPT
$p = New-Partition -DiskNumber $disk.Number -Size 40GB -AssignDriveLetter
Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel Data -Confirm:$false | Out-Null
Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, @{n='GB';e={[int]($_.Size/1GB)}} -Auto
foreach ($d in Get-CimInstance Win32_DiskDrive) { "$($d.Index) $($d.PNPDeviceID) removal policy " + (Get-PnpDeviceProperty -InstanceId $d.PNPDeviceID -KeyName DEVPKEY_Device_RemovalPolicy).Data }
"""), flush=True)


def make_space_stuck(vm):
    """Puts the paging file near the end of C:, with plenty free, as on the PCs in issues #4 and #6. It takes
    it away, fills the disk so it can only come back at the end, then frees it all again. What it fills it
    with isn't written, so the VM's disk doesn't grow. Hibernation stays exactly as Windows set it."""
    print(vm.ps(r"""
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
(Get-ItemProperty $key).PagingFiles | Set-Content C:\probe\paging-before.txt
New-ItemProperty -Path $key -Name PagingFiles -PropertyType MultiString -Value ([string[]]@()) -Force | Out-Null
"paging off"
"""), flush=True)
    restart_and_wait(vm)
    print(vm.ps(r"""
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$free = (Get-Volume -DriveLetter C).SizeRemaining
# Windows puts each file in the smallest gap it fits, so the big file takes the start of the big gap.
$size = [int64]($free - 16GB)
fsutil file createnew C:\probe\filler.bin $size
fsutil file setvaliddata C:\probe\filler.bin $size
# Then little ones, which go in the small gaps first, so what's left free is the big gap's end.
$n = 0
while ((Get-Volume -DriveLetter C).SizeRemaining -gt 5GB) {
    $n++
    fsutil file createnew C:\probe\filler$n.bin 536870912 | Out-Null
    fsutil file setvaliddata C:\probe\filler$n.bin 536870912 | Out-Null
}
New-ItemProperty -Path $key -Name PagingFiles -PropertyType MultiString -Value ([string[]]@(Get-Content C:\probe\paging-before.txt)) -Force | Out-Null
"filler {0:N1} GB, then {1:N1} GB free" -f ($size/1GB), ((Get-Volume -DriveLetter C).SizeRemaining/1GB)
""", timeout=600), flush=True)
    restart_and_wait(vm)
    print(vm.ps(r"""
Remove-Item C:\probe\filler*.bin -Force
Optimize-Volume -DriveLetter C -ReTrim | Out-Null
"filler gone"
""", timeout=600), flush=True)


# --- Scenarios ----------------------------------------------------------------------------------


def scenario_screens(bench):
    """Every screen that doesn't need the disk to change."""
    vm, s = bench.fresh(second_disk=True)
    s.desktop()
    make_second_disk(vm)
    s.get_hop()
    s.open_as_a_person()
    vm.shot('checking')
    s.settle()
    print(s.controls(), flush=True)
    vm.shot('choose')

    # The system picker, at the sentence's first line.
    s.click_hop(236, LINE_ONE_Y)
    time.sleep(1.5)
    vm.shot('system-picker')
    for _ in range(12):
        vm.key('down', hold=40)
        time.sleep(0.1)
    time.sleep(0.5)
    vm.shot('system-picker-scrolled')
    vm.key('esc')
    time.sleep(1)

    # The drive picker, with the second disk.
    s.click_hop(150, LINE_TWO_Y)
    time.sleep(1.5)
    vm.shot('drive-picker')
    s.click_hop(250, DRIVE_ROW_Y + DRIVE_ROW_H)
    time.sleep(8)
    vm.shot('choose-second-drive')
    s.click_hop(150, LINE_TWO_Y)
    time.sleep(1.5)
    vm.shot('drive-picker-on-second')
    s.click_hop(250, DRIVE_ROW_Y)
    time.sleep(8)
    vm.shot('back-on-c')

    # Install asks once more.
    s.press('Install', limit=30)
    time.sleep(3)
    vm.shot('install-pressed')
    if 'Continue' in s.names():
        s.press('Continue')
        time.sleep(2)
        vm.shot('confirm')
    s.press('Back')
    time.sleep(2)

    # Replacing Windows is the row after the drives, for a system that offers it. Nothing starts until the word's typed.
    s.click_hop(236, LINE_ONE_Y)
    time.sleep(1.5)
    s.click_hop(236, SYSTEM_ROW_Y + DRIVE_ROW_H)
    time.sleep(3)
    vm.shot('choose-ubuntu')
    s.click_hop(150, LINE_TWO_Y)
    time.sleep(1.5)
    vm.shot('drive-picker-replace-row')
    drives = vm.ps(r'(Get-Partition | Where-Object DriveLetter).Count').strip()
    s.click_hop(250, DRIVE_ROW_Y + DRIVE_ROW_H * int(drives))
    time.sleep(15)
    vm.shot('replace-warning-1')
    for screen in range(2, 4):
        if 'Continue' not in s.names():
            break
        s.press('Continue')
        time.sleep(2)
        vm.shot(f'replace-warning-{screen}')
    vm.shot('erase-empty')
    vm.type('ERAS')
    time.sleep(1)
    vm.shot('erase-wrong')
    print(s.controls(), flush=True)
    vm.type('E')
    time.sleep(1)
    vm.shot('erase-typed')
    print(s.controls(), flush=True)
    s.press('Cancel')
    time.sleep(2)
    vm.shot('after-cancel')
    s.hop_log()


def make_room(vm, s):
    """From a stuck C:, through the restart, until hop has moved the files and shows what's next."""
    s.open_as_a_person('stuck-elevation-prompt')
    s.settle()
    vm.shot('stuck-choose')
    print(s.names(), flush=True)
    s.press('Make room', limit=60)
    time.sleep(4)
    vm.shot('stuck-make-room')
    before = vm.agent_boot.get('user')
    s.press('Make room and restart', limit=30)
    for second in range(0, 24, 2):
        vm.shot(f'stuck-restarting-{second:02}s')
        time.sleep(2)
    vm.wait_agent('user', limit=600, not_boot=before)
    vm.shot('stuck-signed-in-again')
    s.facts('just after signing in')
    # Hop should come back by itself, with nothing asked. Nothing here answers a prompt, so one would show.
    for second in range(0, 180, 10):
        vm.shot(f'stuck-after-restart-{second:03}s')
        ui = s.ui()
        print(f'{second}s: hop window: {ui.get("found")}', flush=True)
        if ui.get('found'):
            print(vm.ps(FROM_WHERE, timeout=60), flush=True)
            break
        time.sleep(10)
    else:
        raise TimeoutError('hop did not come back by itself')
    vm.shot('stuck-hop-back')
    for minute in range(40):
        names = s.names()
        print(f'{minute}: {names}', flush=True)
        vm.shot(f'stuck-moving-{minute:02}')
        if any(n in ('Install', 'Close', 'Make room') or n.startswith('Use ') for n in names):
            break
        time.sleep(30)
    time.sleep(2)
    vm.shot('stuck-space-made')
    s.facts('after moving files')
    s.hop_log()


def scenario_scales(bench):
    """The screens that hold most text, at 100% and 125%, with the setting a person would use."""
    vm, s = bench.fresh()
    s.desktop()
    s.get_hop()
    for percent, dpi in ((100, 96), (125, 120)):
        vm.ps(f"""
Set-ItemProperty 'HKCU:\\Control Panel\\Desktop' -Name LogPixels -Value {dpi} -Type DWord
Set-ItemProperty 'HKCU:\\Control Panel\\Desktop' -Name Win8DpiScaling -Value 1 -Type DWord
""", timeout=30)
        restart_and_wait(vm)
        time.sleep(15)
        s.open_as_a_person(f'scale{percent}-elevation')
        s.settle()
        vm.shot(f'scale{percent}-choose')
        ui = s.ui()
        print(f'{percent}%: window {ui.get("left")},{ui.get("top")} to {ui.get("right")},{ui.get("bottom")}', flush=True)
        s.press('Install', limit=30)
        time.sleep(3)
        vm.shot(f'scale{percent}-install-pressed')
        if 'Continue' in s.names():
            s.press('Continue')
            time.sleep(3)
            vm.shot(f'scale{percent}-confirm')
        s.press('Back', limit=30)
        time.sleep(2)
        ui = s.ui()
        vm.click(ui['right'] - int(24 * dpi / 96), ui['top'] + int(22 * dpi / 96))
        time.sleep(5)


def scenario_stuck(bench):
    """Make room, for real, then closing hop. The one that had only ever been mocked."""
    vm, s = bench.fresh()
    s.desktop()
    s.facts('as installed')
    make_space_stuck(vm)
    s.facts('after moving the paging file to the end')
    s.get_hop()
    make_room(vm, s)
    # Closing hop is what puts everything back, when no install has.
    ui = s.ui()
    vm.click(ui['right'] - 24, ui['top'] + 22)
    time.sleep(15)
    vm.shot('stuck-closed')
    s.facts('after closing hop')
    restart_and_wait(vm)
    vm.shot('stuck-restarted-again')
    s.facts('after one more restart: are hibernation, the paging file and the journal back?')
    s.hop_log()


def scenario_protect(bench):
    """hop's folder as an earlier build left it, with files an ordinary user planted, then hop opened. The agent
    is elevated, so what it makes is the administrators', which hop rightly trusts. The planted files go to the
    Users group, which is the owner an ordinary user's files can't be told apart from here."""
    vm, s = bench.fresh()
    s.desktop()
    vm.wait_agent('system', limit=300)
    print(vm.ps(r"""
New-Item -ItemType Directory -Force C:\ProgramData\hop\logs | Out-Null
Set-Content C:\ProgramData\hop\logs\earlier.log 'from an earlier build'
Set-Content C:\ProgramData\hop\linux-disks.json '["{earlier}"]'
""", who='system'), flush=True)
    print(vm.ps(r"""
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
"PagingFiles before: " + ((Get-ItemProperty $key).PagingFiles -join ' | ')
Set-Content C:\ProgramData\hop\make-room.json '{"Phase":"ready","Saved":"2030-01-01T00:00:00","Hibernation":false,"PagingOff":true,"Paging":["C:\\planted.sys 1 1"],"Drive":"C:"}'
Set-Content C:\ProgramData\hop\state.json.tmp 'planted'
New-Item -ItemType Directory C:\ProgramData\LinuxHop | Out-Null
Set-Content C:\ProgramData\LinuxHop\state.json '{"Distro":"planted","Partitions":[]}'
foreach ($planted in 'C:\ProgramData\hop\make-room.json', 'C:\ProgramData\hop\state.json.tmp', 'C:\ProgramData\LinuxHop') { icacls $planted /setowner '*S-1-5-32-545' /T | Out-Null }
Get-ChildItem C:\ProgramData\hop -Force | ForEach-Object { "$($_.Name) owner $((Get-Acl $_.FullName).Owner)" }
"LinuxHop owner " + (Get-Acl C:\ProgramData\LinuxHop).Owner
"""), flush=True)
    s.get_hop()
    s.open_as_a_person('protect-elevation-prompt')
    s.settle()
    vm.shot('protect-opened')
    print(s.names(), flush=True)
    print(vm.ps(r"""
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
"PagingFiles after: " + ((Get-ItemProperty $key).PagingFiles -join ' | ')
icacls C:\ProgramData\hop
"owner " + (Get-Acl C:\ProgramData\hop).Owner
Get-ChildItem C:\ProgramData -Force -Filter 'hop*' | ForEach-Object { $_.FullName }
Get-ChildItem C:\ProgramData -Force -Filter 'LinuxHop*' | ForEach-Object { $_.FullName }
Get-ChildItem C:\ProgramData\hop -Recurse -Force | ForEach-Object { "$($_.FullName) owner $((Get-Acl $_.FullName).Owner)" }
"""), flush=True)
    s.hop_log()


def scenario_abandon(bench):
    """Make room, hop killed once it's back, and nobody opens it again. The settings still have to come back."""
    vm, s = bench.fresh()
    s.desktop()
    make_space_stuck(vm)
    s.facts('stuck')
    s.get_hop()
    make_room(vm, s)
    print(vm.ps('Stop-Process -Name hop -Force; Start-Sleep 2; Get-Process hop -ErrorAction SilentlyContinue | Measure-Object | Select-Object Count', timeout=30), flush=True)
    s.facts('hop killed, with the settings still off')
    restart_and_wait(vm)
    vm.shot('abandon-restarted')
    s.facts('restarted: hop opens again from the task if the first task is still there')
    time.sleep(20)
    vm.ps('Stop-Process -Name hop -Force -ErrorAction SilentlyContinue', timeout=30)
    # The task starts 20 minutes after Windows does.
    for minute in range(0, 26, 3):
        time.sleep(180)
        vm.shot(f'abandon-{minute:02}m')
        s.facts(f'{minute + 3} minutes on')
    restart_and_wait(vm)
    s.facts('one more restart: all back, and nothing left of hop?')
    s.hop_log()


def scenario_abandonfast(bench):
    """The same, with the safety-net task started by hand instead of waiting for its 20 minutes."""
    vm, s = bench.fresh()
    s.desktop()
    make_space_stuck(vm)
    s.get_hop()
    make_room(vm, s)
    vm.ps('Stop-Process -Name hop -Force', timeout=30)
    restart_and_wait(vm)
    s.facts('restarted, hop killed, settings still off')
    print(vm.ps(r"""
Get-ScheduledTask 'hop restore settings' | Format-List TaskName, State
$t = Get-ScheduledTask 'hop restore settings'
"delay $($t.Triggers[0].Delay), every $($t.Triggers[0].Repetition.Interval)"
Start-ScheduledTask 'hop restore settings'
Start-Sleep 45
Get-ScheduledTaskInfo -TaskName 'hop restore settings' -ErrorAction SilentlyContinue | Format-List LastRunTime, LastTaskResult
""", timeout=120), flush=True)
    vm.shot('abandonfast-after-task')
    s.facts('after the task ran')
    time.sleep(15)
    restart_and_wait(vm)
    s.facts('one more restart: all back, and nothing left of hop?')
    s.hop_log()


def install(vm, s, tag='install'):
    """Install, from hop's first screen until it says it's ready."""
    s.click_hop(236, LINE_ONE_Y)
    time.sleep(1.5)
    vm.shot(f'{tag}-system-picker')
    s.click_hop(236, SYSTEM_ROW_Y + DRIVE_ROW_H)
    time.sleep(3)
    vm.shot(f'{tag}-choose')
    s.press('Install', limit=30)
    time.sleep(4)
    vm.shot(f'{tag}-asked')
    if 'Continue' in s.names():
        s.press('Continue')
        time.sleep(3)
        vm.shot(f'{tag}-confirm')
    s.press('Start', limit=30)
    for minute in range(60):
        time.sleep(30)
        vm.shot(f'{tag}-progress-{minute:02}')
        names = s.names()
        print(f'{minute}: {names}', flush=True)
        if 'Restart now' in names or 'Try again' in names or 'Clean up' in names:
            break
    time.sleep(2)
    vm.shot(f'{tag}-ended')
    s.facts(f'{tag} ended')
    print(vm.ps('bcdedit /enum firmware; mountvol S: /s; Get-ChildItem S:\\EFI -Recurse -Depth 1 | Select-Object FullName; mountvol S: /d', timeout=60), flush=True)
    s.hop_log()


LIVE_REPORT = 'wget -qO- 10.0.2.2:8765/file/live-report.sh | sudo sh\n'


def restart_into_linux(vm, s):
    """Restart now, and what the firmware does next. The screen is how to tell."""
    before = vm.agent_boot.get('user')
    s.press('Restart now', limit=30)
    for second in range(0, 420, 15):
        time.sleep(15)
        vm.shot(f'linux-{second:03}s')
    return before


def scenario_install(bench):
    """A real Ubuntu, downloaded, shrunk, copied and started, with Windows' recovery partition ending the disk."""
    vm, s = bench.fresh()
    s.desktop()
    s.facts('as installed')
    s.get_hop()
    s.open_as_a_person('install-elevation-prompt')
    s.settle()
    install(vm, s)
    before = restart_into_linux(vm, s)
    vm.key('ctrl', 'alt', 't')
    time.sleep(10)
    vm.shot('linux-terminal')
    vm.type(LIVE_REPORT)
    time.sleep(10)
    vm.shot('linux-report')
    time.sleep(5)
    vm.type('sudo systemctl reboot -i\n')
    undo_after_linux(vm, s, before)


def undo_after_linux(vm, s, before):
    """Back in Windows from the live system: hop's Undo, and whether it all went back."""
    for second in range(0, 240, 20):
        time.sleep(20)
        vm.shot(f'back-{second:03}s')
        if vm.agent_boot.get('user') != before:
            break
    vm.wait_agent('user', limit=600, not_boot=before)
    vm.shot('back-in-windows')
    s.facts('back in Windows')
    print(vm.ps('bcdedit /enum firmware', timeout=60), flush=True)
    s.open_as_a_person('undo-elevation-prompt')
    s.settle()
    vm.shot('undo-hop-opens')
    print(s.controls(), flush=True)
    s.press('Undo changes', limit=30)
    time.sleep(2)
    vm.shot('undo-options')
    print(s.controls(), flush=True)
    # The first row: "Linux isn't installed yet".
    s.click_hop(300, 240)
    time.sleep(1)
    vm.shot('undo-chosen')
    s.press('Remove', limit=30)
    for minute in range(20):
        time.sleep(30)
        vm.shot(f'undo-progress-{minute:02}')
        if 'Close' in s.names() or 'Try again' in s.names():
            break
    vm.shot('undo-ended')
    s.facts('after Undo')
    print(vm.ps('bcdedit /enum firmware; mountvol S: /s; Get-ChildItem S:\\EFI | Select-Object Name; mountvol S: /d', timeout=60), flush=True)
    s.hop_log()
    ui = s.ui()
    vm.click(ui['right'] - 24, ui['top'] + 22)
    restart_and_wait(vm)
    vm.shot('undo-windows-still-starts')
    s.facts('after Undo and a restart')


def scenario_stuckinstall(bench):
    """Make room, then the install it was for. Installing is what should put the settings back."""
    vm, s = bench.fresh()
    s.desktop()
    s.facts('as installed')
    make_space_stuck(vm)
    s.facts('after moving the paging file to the end')
    s.get_hop()
    make_room(vm, s)
    install(vm, s, tag='room-install')
    restart_and_wait(vm)
    vm.shot('room-install-restarted')
    s.facts('installed after Make room, restarted: are they all back?')
