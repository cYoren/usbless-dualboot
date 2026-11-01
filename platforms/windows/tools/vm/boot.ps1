# In the VM's disk image. Fetches the current agent from the host each time, so changing the agent
# doesn't mean installing Windows again.
param([string]$Who = 'user')
while ($true) {
    try {
        $agent = (New-Object Net.WebClient).DownloadString('http://10.0.2.2:8765/file/agent.ps1')
        Set-Content -LiteralPath "C:\probe\agent-$Who.ps1" -Value $agent -Encoding UTF8
        & "C:\probe\agent-$Who.ps1" -Who $Who
    } catch { }
    Start-Sleep -Seconds 5
}
