# --- Official download sources -----------------------------------------

function Get-WebText([string]$Url) {
    for ($attempt = 1; ; $attempt++) {
        try {
            $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60).Content
            if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
            return $content
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            # A missing release/checksum does not become available by repeating
            # the same request. Keep retries for timeouts, rate limits and 5xx.
            if ($attempt -ge 3 -or ($status -ge 400 -and $status -lt 500 -and $status -notin 408, 429)) { throw }
            Write-Log "Trying $Url again: $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
}

# The user's Downloads folder, wherever they have moved it, or a folder on the drive asked for.
function Get-DownloadFolder([string]$Drive) {
    $folder = try { (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch { $null }
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { $folder = Join-Path $env:USERPROFILE 'Downloads' }
    if ($Drive -and -not $folder.StartsWith("$Drive`:", [StringComparison]::OrdinalIgnoreCase)) { $folder = "$Drive`:\usbless" }
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $folder
}

function ConvertTo-Version([string]$Text) {
    if ($Text -notmatch '\.') { $Text += '.0' }
    [version]$Text
}

function New-Download([string]$Url, [string]$Sha256, [int64]$Size) {
    [pscustomobject]@{ Url = $Url; Sha256 = $Sha256; Size = $Size; FileName = ([uri]$Url).Segments[-1] }
}

function Resolve-Download($Distro) {
    switch ($Distro.Kind) {
        'ubuntu' {
            # SHA256SUMS lists every point release; take the newest desktop ISO.
            $sums = Get-WebText ($Distro.Base + 'SHA256SUMS')
            $pattern = '(?m)^([0-9a-f]{64}) \*?(' + [regex]::Escape($Distro.Prefix) + '-([\d.]+)-desktop-amd64\.iso)\s*$'
            $best = $null
            foreach ($m in [regex]::Matches($sums, $pattern)) {
                $v = ConvertTo-Version $m.Groups[3].Value
                if (-not $best -or $v -gt $best.Version) { $best = @{ Version = $v; Sha = $m.Groups[1].Value; File = $m.Groups[2].Value } }
            }
            if (-not $best) { throw "Could not find the $($Distro.Name) ISO on $($Distro.Source)." }
            return New-Download ($Distro.Base + $best.File) $best.Sha 0
        }
        'mint' {
            $base = 'https://mirrors.edge.kernel.org/linuxmint/stable/'
            $versions = [regex]::Matches((Get-WebText $base), 'href="(\d+(?:\.\d+)?)/"') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object { ConvertTo-Version $_ } -Descending
            foreach ($v in $versions) {
                try { $sums = Get-WebText "$base$v/sha256sum.txt" } catch { continue }
                $m = [regex]::Match($sums, "(?m)^([0-9a-f]{64}) \*?(linuxmint-[\d.]+-$($Distro.Edition)-64bit\.iso)")
                if ($m.Success) { return New-Download "$base$v/$($m.Groups[2].Value)" $m.Groups[1].Value 0 }
            }
            throw 'Could not find the Linux Mint ISO on the mirror.'
        }
        'pop' {
            $build = Invoke-RestMethod -Uri 'https://api.pop-os.org/builds/24.04/generic' -UseBasicParsing -TimeoutSec 60
            return New-Download $build.url $build.sha_sum ([int64]$build.size)
        }
        'elementary' {
            # The link carries an expiring token, so read it from the site each time.
            # elementary does not publish a checksum; the download is HTTPS from their server.
            $m = [regex]::Match((Get-WebText 'https://elementary.io/'), 'https://dl\.elementaryos\.org/[^"''\s<>]+-amd64[^"''\s<>]*\.iso')
            if (-not $m.Success) { throw 'Could not find the download link on elementary.io.' }
            return New-Download $m.Value $null 0
        }
        'zorin' {
            $base = 'https://mirrors.edge.kernel.org/zorinos-isos/'
            $majors = [regex]::Matches((Get-WebText $base), 'href="(\d+)/"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Descending
            foreach ($major in $majors) {
                try { $sums = Get-WebText "$base$major/SHA256SUMS.txt" } catch { continue }
                # Rereleases of a version are named -r1, -r2 and so on.
                $best = $null
                foreach ($m in [regex]::Matches($sums, '(?m)^([0-9a-f]{64})\s+\*?(Zorin-OS-([\d.]+)-Core-64-bit(?:-r(\d+))?\.iso)\s*$')) {
                    $v = ConvertTo-Version $m.Groups[3].Value
                    $r = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 0 }
                    if (-not $best -or $v -gt $best.Version -or ($v -eq $best.Version -and $r -gt $best.Revision)) {
                        $best = @{ Version = $v; Revision = $r; Sha = $m.Groups[1].Value; File = $m.Groups[2].Value }
                    }
                }
                if ($best) { return New-Download "$base$major/$($best.File)" $best.Sha 0 }
            }
            throw 'Could not find the Zorin OS ISO on the mirror.'
        }
        'debian' {
            $base = 'https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/'
            $m = [regex]::Match((Get-WebText ($base + 'SHA256SUMS')), '(?m)^([0-9a-f]{64}) \*?\s*(debian-live-[\d.]+-amd64-gnome\.iso)\s*$')
            if (-not $m.Success) { throw 'Could not find the Debian live ISO on cdimage.debian.org.' }
            return New-Download ($base + $m.Groups[2].Value) $m.Groups[1].Value 0
        }
        'fedora' {
            # Fedora's own list has beta releases too, whose version isn't a plain number.
            $variant = if ($Distro.Edition) { $Distro.Edition } else { 'Workstation' }
            $best = @(Invoke-RestMethod -Uri 'https://fedoraproject.org/releases.json' -UseBasicParsing -TimeoutSec 60) |
                ForEach-Object { $_ } |
                Where-Object { $_.variant -eq $variant -and $_.arch -eq 'x86_64' -and $_.version -match '^\d+$' -and $_.link -like '*.iso' } |
                Sort-Object { [int]$_.version } -Descending | Select-Object -First 1
            if (-not $best) { throw "Could not find Fedora $variant in the list on fedoraproject.org." }
            return New-Download $best.link $best.sha256 ([int64]$best.size)
        }
        'ultramarine' {
            $base = 'https://images.fyralabs.com/isos/ultramarine/'
            $versions = [regex]::Matches((Get-WebText $base), 'href="(\d+)/"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Descending
            foreach ($v in $versions) {
                $file = "ultramarine-$($Distro.Edition)-$v-live-anaconda-x86_64.iso"
                try { $sums = Get-WebText "$base$v/$file.sha256sum" } catch { continue }
                $m = [regex]::Match($sums, '^[0-9a-f]{64}')
                if ($m.Success) { return New-Download "$base$v/$file" $m.Value 0 }
            }
            throw 'Could not find the Ultramarine ISO on images.fyralabs.com.'
        }
        'cachyos' {
            # cachyos.org and its main mirror only speak TLS 1.3, which Windows 10 can't. Their CDN has
            # the files and the checksums but no folder list, so the first mirror on their download page says which builds exist.
            $builds = [regex]::Matches((Get-WebText 'https://mirror.zyner.org/cachyos/ISO/desktop/'), 'href="(\d{6})/"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Descending
            foreach ($build in $builds) {
                $url = "https://cdn77.cachyos.org/ISO/desktop/$build/cachyos-desktop-linux-$build.iso"
                try { $sums = Get-WebText "$url.sha256" } catch { continue }
                $m = [regex]::Match($sums, '^[0-9a-f]{64}')
                if ($m.Success) { return New-Download $url $m.Value 0 }
            }
            throw "Could not find the CachyOS ISO on CachyOS's download servers."
        }
        'omarchy' {
            $m = [regex]::Match((Get-WebText 'https://omarchy.org/'), 'https://iso\.omarchy\.org/omarchy-((\d+\.\d+)\.\d+)\.iso')
            if (-not $m.Success) { throw 'Could not find the Omarchy ISO on omarchy.org.' }
            # Later versions install from a separate image on the medium, which is gone by the time this one's installer looks.
            if ($m.Groups[2].Value -ne '4.0') { throw "omarchy.org now offers version $($m.Groups[1].Value), and usbless has only tried 4.0." }
            $sum = [regex]::Match((Get-WebText "$($m.Value).sha256"), '^[0-9a-f]{64}')
            if (-not $sum.Success) { throw 'Could not find the checksum for the Omarchy ISO.' }
            return New-Download $m.Value $sum.Value 0
        }
        'arch' {
            $base = 'https://geo.mirror.pkgbuild.com/iso/latest/'
            $m = [regex]::Match((Get-WebText ($base + 'sha256sums.txt')), '(?m)^([0-9a-f]{64}) \*?\s*(archlinux-\d{4}\.\d{2}\.\d{2}-x86_64\.iso)\s*$')
            if (-not $m.Success) { throw 'Could not find the Arch Linux ISO on the mirror.' }
            return New-Download ($base + $m.Groups[2].Value) $m.Groups[1].Value 0
        }
    }
    throw "Unknown system '$($Distro.Id)'."
}

# --- Download ------------------------------------------------------------

function Test-Sha256([string]$Path, [string]$Expected) {
    Set-Stage 2
    Set-Status 'Checking the download is genuine (takes a minute)...'
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected.ToUpperInvariant()
}

# Refuses early rather than filling the drive and failing an hour in.
function Assert-DownloadRoom([string]$Path, [int64]$Total, [int64]$Done) {
    $needed = $(if ($Total) { $Total } else { 7GB }) - $Done + 1GB
    $root = [IO.Path]::GetPathRoot($Path)
    $free = ([IO.DriveInfo]$root).AvailableFreeSpace
    if ($free -lt $needed) {
        throw ('The download needs {0:N0} GB free on {1} and only {2:N0} GB is free. Free up some space, choose another drive for the download, or download the ISO yourself and pick "Use an ISO file".' -f ($needed / 1GB), $root, ($free / 1GB))
    }
}

# curl.exe ignores Windows' proxy setting, so pass it on.
function Get-CurlProxy([string]$Url) {
    try {
        $proxy = [Net.WebRequest]::GetSystemWebProxy().GetProxy([uri]$Url)
        if ($proxy -and $proxy.AbsoluteUri -ne ([uri]$Url).AbsoluteUri) { $proxy.AbsoluteUri }
    } catch { }
}

function Get-CurlMessage([int]$Code) {
    switch ($Code) {
        5 { return "Couldn't reach the proxy set in Windows. Check its settings, or try another network, and click Install again; it will pick up where it left off." }
        { $_ -in 6, 7 } { return "Couldn't reach the download server. Check the internet connection and click Install again; it will pick up where it left off." }
        56 { return "The connection dropped, or a work network's proxy refused it. Try another network, or download the ISO yourself and pick ""Use an ISO file""." }
        23 { return "Couldn't save the download. Check the drive has free space and click Install again." }
        28 { return 'The download stalled. Check the internet connection and click Install again; it will pick up where it left off.' }
        { $_ -in 35, 60 } { return "A secure connection to the download server failed. Check this PC's date and time are correct, then click Install again." }
    }
    if ($Code -eq 22) { return 'The download server returned an error. It may be busy, or a proxy may be blocking it. Click Install again later; it will pick up where it left off.' }
    "The download stopped (curl error $Code). Check the internet connection and click Install again; it will pick up where it left off."
}

function Invoke-Curl([string]$Url, [string]$Part, [int64]$Total, [string]$Name) {
    # -C - resumes a half-finished download if Install is clicked again. The speed limit
    # ends a connection that has quietly died, which --retry then reopens.
    $curlArgs = @('-L', '--fail', '--silent', '--show-error', '--retry', '5', '--retry-delay', '5',
        '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '120',
        '-C', '-', '-o', "`"$Part`"", "`"$Url`"")
    $proxy = Get-CurlProxy $Url
    # An empty -U : means sign in to the proxy as the current Windows user.
    if ($proxy) { $curlArgs = @('--proxy', "`"$proxy`"", '--proxy-anyauth', '-U', ':') + $curlArgs }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $proc = Start-Process -FilePath $curl -ArgumentList $curlArgs -PassThru -WindowStyle Hidden
    $null = $proc.Handle   # keeps ExitCode readable after the process exits
    $Sync.ChildPid = $proc.Id   # lets the app stop the download if it is closed
    Set-Status "Downloading $Name..."
    while (-not $proc.HasExited) {
        if ($Total -and (Test-Path -LiteralPath $Part)) {
            $done = (Get-Item -LiteralPath $Part).Length
            $Sync.Status = 'Downloading {0}... {1:N1} of {2:N1} GB' -f $Name, ($done / 1GB), ($Total / 1GB)
            Set-ByteProgress $done $Total
        }
        Start-Sleep -Milliseconds 700
    }
    $Sync.ChildPid = $null   # that number can go to another process now
    $proc.ExitCode
}

function Test-ServerAnswers([string]$Url) {
    try { [void](Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 60); $true } catch { $false }
}

function Test-CurlAvailable {
    Test-Path (Join-Path $env:SystemRoot 'System32\curl.exe')
}

function Preserve-Download([string]$Path, [string]$Reason) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $saved = "$Path.saved-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmss'))-$([guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $Path -Destination $saved -ErrorAction Stop
    Write-Log "$Reason Kept the existing bytes in $saved"
}

function Invoke-Download($Download, [string]$Path) {
    Set-Stage 1
    $part = "$Path.part"
    $total = $Download.Size
    if (-not $total) {
        try {
            $head = Invoke-WebRequest -Uri $Download.Url -Method Head -UseBasicParsing -TimeoutSec 60
            $total = [int64]($head.Headers['Content-Length'] | Select-Object -First 1)
        } catch { $total = 0 }
    }
    $done = if (Test-Path -LiteralPath $part) { (Get-Item -LiteralPath $part).Length } else { 0 }
    # Bigger than the real file means it came from a different release.
    if ($total -and $done -gt $total) {
        Preserve-Download $part 'The partial file is larger than this release.'
        $done = 0
    }
    Assert-DownloadRoom $Path $total $done

    if ($total -and $done -eq $total) {
        Write-Log 'Download already complete.'
    } elseif (-not (Test-CurlAvailable)) {
        Set-Status "Downloading $($Download.FileName)..."
        Start-BitsTransfer -Source $Download.Url -Destination $part
    } else {
        $code = Invoke-Curl $Download.Url $part $total $Download.FileName
        # 22 and 33: the server refused to resume, usually because the partial file is already
        # whole or is from an older link. Start from zero once, but only if the server is
        # answering: 22 is also any HTTP error, and that shouldn't cost gigabytes of progress.
        if ($code -in 22, 33 -and (Test-Path -LiteralPath $part) -and (Test-ServerAnswers $Download.Url)) {
            Preserve-Download $part "The server would not resume the download (curl error $code)."
            $code = Invoke-Curl $Download.Url $part $total $Download.FileName
        }
        if ($code -ne 0) { throw (Get-CurlMessage $code) }
    }

    $size = (Get-Item -LiteralPath $part).Length
    if ($total -and $size -ne $total) {
        Preserve-Download $part 'The downloaded size differs from the publisher size.'
        throw ('The download came out the wrong size ({0:N0} bytes, expected {1:N0}). Click Install to download it again.' -f $size, $total)
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
}

function Get-Iso($Download, [string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not $Download.Sha256 -or (Test-Sha256 $Path $Download.Sha256)) {
            Write-Log "Using the copy already in $Path"
            return
        }
        Preserve-Download $Path 'The existing file does not match this release checksum.'
    }
    Invoke-Download $Download $Path
    if ($Download.Sha256) {
        if (-not (Test-Sha256 $Path $Download.Sha256)) {
            Preserve-Download $Path 'The new download does not match the publisher checksum.'
            throw 'The downloaded file is damaged (checksum does not match). Click Install to download it again.'
        }
        Write-Log 'Checksum matches the official one.'
    } else {
        Write-Log 'This project does not publish a checksum. The file came over a secure HTTPS connection from its official server.'
    }
}
