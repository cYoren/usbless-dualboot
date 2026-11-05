# Checks every system in the catalog still resolves to a real download, against the live
# servers. Reads from the web only; nothing is downloaded and the disk isn't touched.
# Run weekly by CI, because projects move their files without warning.

$root = Split-Path $PSScriptRoot -Parent
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'check' })
. (Join-Path $root 'engine\Common.ps1')
foreach ($module in Get-ChildItem (Join-Path $root 'engine\*.ps1') | Where-Object Name -ne 'Common.ps1') { . $module.FullName }
function Write-Log([string]$Message) { }

$failed = 0
foreach ($distro in Get-Catalog) {
    try {
        $download = Resolve-Download $distro
        $head = Invoke-WebRequest -Uri $download.Url -Method Head -UseBasicParsing -TimeoutSec 60
        $size = [int64]($head.Headers['Content-Length'] | Select-Object -First 1)
        Write-Output ('ok    {0,-20} {1:N1} GB  {2}' -f $distro.Id, ($size / 1GB), $download.FileName)
    } catch {
        $failed++
        Write-Output ('FAIL  {0,-20} {1}' -f $distro.Id, $_.Exception.Message)
    }
}
if ($failed) {
    Write-Output "$failed of the catalog could not be resolved."
    exit 1
}
