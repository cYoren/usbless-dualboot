# Runs what the host sends, one script at a time, and posts back what it printed.
param([string]$Who = 'user')
$base = 'http://10.0.2.2:8765'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s')

function Invoke-Job($Job) {
    $script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Job.script))
    $path = "C:\probe\job-$Who-$($Job.id).ps1"
    $out = "C:\probe\job-$Who-$($Job.id).txt"
    [IO.File]::WriteAllText($path, $script, (New-Object Text.UTF8Encoding($true)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"& '$path' *>&1 | Out-File -LiteralPath '$out' -Encoding utf8 -Width 400`""
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $note = ''
    if (-not $process.WaitForExit([int]$Job.timeout * 1000)) {
        $note = "`n[the agent stopped this after $($Job.timeout) seconds]"
        try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { }
    }
    $text = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
    Remove-Item -LiteralPath $path, $out -Force -ErrorAction SilentlyContinue
    $bytes = [Text.Encoding]::UTF8.GetBytes("$text$note")
    (New-Object Net.WebClient).UploadData("$base/result?id=$($Job.id)", 'POST', $bytes) | Out-Null
}

while ($true) {
    try {
        $client = New-Object Net.WebClient
        $reply = $client.DownloadString("$base/next?who=$Who&boot=$boot")
    } catch {
        Start-Sleep -Seconds 3
        continue
    }
    if (-not $reply) { continue }
    try { Invoke-Job ($reply | ConvertFrom-Json) } catch {
        try { (New-Object Net.WebClient).UploadString("$base/log", "agent $Who`: $($_.Exception.Message)") | Out-Null } catch { }
    }
}
