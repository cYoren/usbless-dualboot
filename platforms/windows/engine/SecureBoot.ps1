# --- Will Secure Boot let this system start? -----------------------------
# Firmware that refuses a boot loader says nothing and starts Windows instead, so this is
# worked out before the disk changes, from the ISO's own files and the PC's trusted list.

function Test-SecureBoot {
    try { [bool](Confirm-SecureBootUEFI) } catch { $false }
}

# An EFI program's signature table as text, where certificate names can be read. Empty when unsigned.
function Get-EfiSignature([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return '' }
    $header = [BitConverter]::ToInt32($bytes, 0x3C) + 24
    if ($header -lt 24 -or $header + 144 -gt $bytes.Length) { return '' }
    # The certificate table is the fifth data directory, which starts later in 64-bit programs.
    $directories = $header + $(if ([BitConverter]::ToUInt16($bytes, $header) -eq 0x20B) { 112 } else { 96 })
    [int64]$offset = [BitConverter]::ToUInt32($bytes, $directories + 32)
    [int64]$size = [BitConverter]::ToUInt32($bytes, $directories + 36)
    if (-not $size -or $offset + $size -gt $bytes.Length) { return '' }
    [Text.Encoding]::GetEncoding(28591).GetString($bytes, [int]$offset, [int]$size)
}

# Microsoft's third-party certificates named in a signature or the PC's list: the 2011 one, the 2023 one, or both.
function Get-UefiAuthorities([string]$Text) {
    @([regex]::Matches($Text, 'Microsoft (?:Corporation )?UEFI CA \d{4}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
}

# The certificates this PC's firmware trusts, as text. Null if it won't say.
function Get-SecureBootDb {
    try { [Text.Encoding]::GetEncoding(28591).GetString((Get-SecureBootUEFI -Name db).Bytes) } catch { $null }
}

# Where the ISO's menu says the first kernel is. Memory testers also use the linux command.
function Get-IsoKernelPath([string]$Root) {
    # Fedora keeps its menu in grub2, and writes ($root) before its paths.
    $menu = @('boot\grub\grub.cfg', 'boot\grub2\grub.cfg') | ForEach-Object { Join-Path $Root $_ } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $menu) { return }
    $m = [regex]::Match((Get-Content -LiteralPath $menu -Raw), '(?m)^\s*linux(?:efi)?\s+(?:\(\$root\))?(/(?!boot/memtest)\S+)')
    if ($m.Success) { Join-Path $Root ($m.Groups[1].Value.TrimStart('/') -replace '/', '\') }
}

# The kernel the ISO's menu starts first.
function Get-IsoKernel([string]$Root) {
    $path = Get-IsoKernelPath $Root
    if ($path -and (Test-Path -LiteralPath $path)) { $path }
}

function Get-SecureBootAdvice {
    $advice = "Turn off Secure Boot in this PC's BIOS settings, then open usbless and install again."
    if (Test-BitLockerOn) { $advice += ' Have your BitLocker recovery key ready first, because Windows may ask for it.' }
    $advice
}

# Why Secure Boot would stop the ISO mounted at $Root, or nothing if it shouldn't.
function Get-SecureBootProblem([string]$Root) {
    if (-not (Test-SecureBoot)) { return }
    $signature = Get-EfiSignature (Join-Path $Root 'EFI\BOOT\BOOTX64.EFI')
    if (-not $signature) { return "This ISO's boot loader isn't signed, so Secure Boot won't start it. $(Get-SecureBootAdvice)" }

    $authorities = @(Get-UefiAuthorities $signature)
    $db = Get-SecureBootDb
    # Only a list that names Microsoft is one this was able to read. Stopping an install on anything less would be a guess.
    if ($authorities.Count -and $db -and $db.Contains('Microsoft') -and -not @($authorities | Where-Object { $db.Contains($_) }).Count) {
        return "This PC's Secure Boot doesn't trust this ISO's boot loader, which is signed by $($authorities -join ' and '). Some BIOS settings have an option to allow Microsoft's third-party certificate; turn it on if yours does. Otherwise: $(Get-SecureBootAdvice)"
    }

    $kernel = Get-IsoKernel $Root
    if ($kernel -and -not (Get-EfiSignature $kernel)) {
        return "This system's Linux kernel isn't signed, so it won't start with Secure Boot on. $(Get-SecureBootAdvice)"
    }
}

# Before a long download, for systems known not to start with Secure Boot on.
function Assert-SecureBootAllows($Distro) {
    if ($Distro.SecureBootOff -and (Test-SecureBoot)) {
        throw "$($Distro.Name) doesn't start with Secure Boot on. $(Get-SecureBootAdvice)"
    }
}
