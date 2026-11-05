# Unit tests for telling a disk inside the PC from a Thunderbolt or USB4 one. In a file of their own because
# the other test files stand in for Get-DiskAttachment. No real Thunderbolt hardware has been tried:
# these only say what usbless does with the answers Windows is documented to give.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1')
    Mock Write-Log { }

    $disk = [pscustomobject]@{ Number = 1 }

    # The disk's device, then each parent in turn, by their removal policies.
    function Set-Chain([object[]]$Policies) {
        $script:chain = @{}
        for ($i = 0; $i -lt $Policies.Count; $i++) {
            $script:chain["dev$i"] = @{ Policy = $Policies[$i]; Parent = if ($i + 1 -lt $Policies.Count) { "dev$($i + 1)" } else { $null } }
        }
    }
}

Describe 'Get-DiskAttachment' {
    BeforeEach {
        Mock Get-CimInstance { [pscustomobject]@{ PNPDeviceID = 'dev0'; MediaType = 'Fixed hard disk media' } } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Mock Get-DeviceProperty {
            $node = $script:chain[$InstanceId]
            if ($Key -eq 'DEVPKEY_Device_Parent') { $node.Parent } else { $node.Policy }
        }
    }
    It 'calls a disk internal when neither it nor anything above it expects removal' {
        Set-Chain @(1, 1, 1, $null)
        Get-DiskAttachment $disk | Should -Be 'internal'
    }
    It 'calls a disk external when its own policy is <policy>' -ForEach @(@{ policy = 2 }, @{ policy = 3 }) {
        Set-Chain @($policy, 1)
        Get-DiskAttachment $disk | Should -Be 'external'
    }
    It 'calls a disk external when a slot above it can be unplugged' {
        Set-Chain @(1, 1, 2, 1)
        Get-DiskAttachment $disk | Should -Be 'external'
    }
    It 'calls a disk external when Windows says its media is <media>' -ForEach @(@{ media = 'External hard disk media' }, @{ media = 'Removable media' }) {
        Set-Chain @(1)
        Mock Get-CimInstance { [pscustomobject]@{ PNPDeviceID = 'dev0'; MediaType = $media } } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Get-DiskAttachment $disk | Should -Be 'external'
    }
    It 'cannot tell when Windows has no policy for the disk' {
        Set-Chain @($null, 1)
        Get-DiskAttachment $disk | Should -Be 'unclear'
    }
    It 'cannot tell when the disk has no device' {
        Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Get-DiskAttachment $disk | Should -Be 'unclear'
    }
    It 'cannot tell when asking fails' {
        Mock Get-CimInstance { throw 'WMI is broken' } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Get-DiskAttachment $disk | Should -Be 'unclear'
    }
    It 'ignores a parent that has no policy, or whose policy cannot be read' {
        Set-Chain @(1, $null, 1)
        Get-DiskAttachment $disk | Should -Be 'internal'
        Mock Get-DeviceProperty {
            if ($Key -eq 'DEVPKEY_Device_Parent') { if ($InstanceId -eq 'dev0') { 'dev1' } else { $null } }
            elseif ($InstanceId -eq 'dev1') { throw 'no such property' }
            else { 1 }
        }
        Get-DiskAttachment $disk | Should -Be 'internal'
    }
    It 'stops at a parent loop rather than hanging' {
        Mock Get-DeviceProperty { if ($Key -eq 'DEVPKEY_Device_Parent') { 'dev0' } else { 1 } }
        Get-DiskAttachment $disk | Should -Be 'internal'
    }
}
