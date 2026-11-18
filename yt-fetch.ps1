#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Portable YouTube fetcher -works on any Windows machine with Python 3.9+.

.DESCRIPTION
    Self-contained version of yt-fetch. No hardcoded paths: Python and Node are
    auto-detected (bundled runtime, PATH, or py launcher). yt-dlp is installed
    into a local venv on first run, so the target machine needs nothing but Python.

    Two access modes are supported, chosen automatically:
      * proxy mode  -if a local HTTP proxy answers on $ProxyPort
      * direct mode -otherwise connect straight out (works outside mainland China)
    YouTube blocks anonymous datacenter/proxy exits with "Sign in to confirm you're
    not a bot"; cookies from a logged-in browser profile fix that.

.PARAMETER Url
    Watch URL, youtu.be link, or bare 11-character video id.

.PARAMETER Mode
    info | subs | audio | video | cookies   (default: info)

.PARAMETER Format
    yt-dlp format selector. Defaults: audio -> 140/bestaudio,
    video -> bv*[height<=720]+ba/b[height<=720]

.PARAMETER ProxyPort
    Local HTTP proxy port to try (default 10808). Use 0 to force direct mode.

.PARAMETER Browser
    If the cookie jar is missing, export cookies from this browser
    (chrome | edge | firefox). Default: chrome

.EXAMPLE
    .\yt-fetch.ps1 -Url TI66H3VDE3Y -Mode info

.EXAMPLE
    .\yt-fetch.ps1 -Url <URL> -Mode cookies -Browser edge
#>
param(
    [string]$Url = '',
    [ValidateSet('info', 'subs', 'audio', 'video', 'cookies')]
    [string]$Mode = 'info',
    [string]$Format = '',
    [int]$ProxyPort = 10808,
    [string]$Browser = 'chrome',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not (Test-Path (Join-Path $Root 'scripts'))) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not $Out) { $Out = Join-Path $Root 'out' }
$CookieJar = Join-Path $Root 'cookies.txt'
$CacheDir = Join-Path $Root 'cache'
$VenvDir = Join-Path $Root '.venv'

New-Item -ItemType Directory -Force -Path $Out, $CacheDir | Out-Null

# ----------------------------------------------------------------- locate python
function Find-Python {
    $candidates = @()
    if ($env:YTDLP_PYTHON) { $candidates += $env:YTDLP_PYTHON }
    $candidates += (Join-Path $Root '.venv\Scripts\python.exe')
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
    }
    # Common manual install locations.
    $candidates += @(
        'C:\Python313\python.exe', 'C:\Python312\python.exe',
        'C:\Python311\python.exe', 'C:\Python310\python.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe')
    )

    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path $c)) { continue }
        # The Windows Store shim under WindowsApps only prints an install advert.
        if ($c -like '*WindowsApps*') { continue }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $v = & $c -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $line = ($v | Where-Object { $_ -match '^\d+\.\d+$' } | Select-Object -First 1)
                if ($line) {
                    $parts = $line.ToString().Split('.')
                    if ([int]$parts[0] -ge 3 -and [int]$parts[1] -ge 8) { return $c }
                }
            }
        } catch { }
        finally { $ErrorActionPreference = $prev }
    }
    throw @"
Python 3.8+ not found.
  Install it from https://python.org (tick "Add python.exe to PATH"),
  or point YTDLP_PYTHON at an existing interpreter:
      `$env:YTDLP_PYTHON = 'C:\path\to\python.exe'
"@
}

$Python = Find-Python
Write-Verbose "python: $Python"

# ------------------------------------------------------- ensure yt-dlp available
# Preference order:
#   1. vendored yt_dlp\ next to this script  (offline, no pip needed)
#   2. an existing install reachable by the found python
#   3. install from PyPI into a local venv   (needs network)
function Try-YtDlpVersion {
    param([string]$Py)
    # Run out-of-process and treat ANY failure as "not usable". Native stderr
    # cannot be silenced with 2>$null in PS 5.1 without tripping ErrorActionPreference.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Py -c "import yt_dlp;print(yt_dlp.version.__version__)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $line = ($out | Where-Object { $_ -match '^\d{4}\.\d{1,2}\.\d{1,2}' } | Select-Object -First 1)
            if ($line) { return $line.ToString().Trim() }
        }
    } catch { }
    finally { $ErrorActionPreference = $prev }
    return $null
}

function Ensure-YtDlp {
    param([string]$Py)

    $vendor = Join-Path $Root 'vendor'
    if (Test-Path (Join-Path $vendor 'yt_dlp\version.py')) {
        $v = Try-YtDlpVersion -Py $Py
        if ($v) { return @{ Version = $v; Python = $Py; Env = @{} } }

        # Retry with the vendored dir on sys.path.
        $env:PYTHONPATH = $vendor
        $v = Try-YtDlpVersion -Py $Py
        if ($v) { return @{ Version = $v; Python = $Py; Env = @{ PYTHONPATH = $vendor } } }
    }

    $v = Try-YtDlpVersion -Py $Py
    if ($v) { return @{ Version = $v; Python = $Py; Env = @{} } }

    Write-Host "yt-dlp not found -installing into local venv (one time)..." -ForegroundColor Cyan
    if (-not (Test-Path (Join-Path $VenvDir 'Scripts\python.exe'))) {
        & $Py -m venv $VenvDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "venv failed, trying --user install instead" -ForegroundColor Yellow
            & $Py -m pip install --upgrade --user yt-dlp
            if ($LASTEXITCODE -ne 0) { throw "failed to install yt-dlp (pip) -no network and no vendored copy?" }
            return @{ Version = (Try-YtDlpVersion -Py $Py); Python = $Py; Env = @{} }
        }
    }
    $venvPy = Join-Path $VenvDir 'Scripts\python.exe'
    & $venvPy -m pip install --upgrade pip --quiet
    & $venvPy -m pip install --upgrade yt-dlp
    if ($LASTEXITCODE -ne 0) { throw "failed to install yt-dlp into venv (no network?)" }
    return @{ Version = (Try-YtDlpVersion -Py $venvPy); Python = $venvPy; Env = @{} }
}

$yt = Ensure-YtDlp -Py $Python
$script:ActivePython = $yt.Python
foreach ($k in $yt.Env.Keys) { Set-Item -Path "env:$k" -Value $yt.Env[$k] }
Write-Verbose "yt-dlp: $($yt.Version) (python: $script:ActivePython)"

# --------------------------------------------------------------- find JS runtime
function Find-Node {
    $candidates = @()
    if ($env:YTDLP_NODE) { $candidates += $env:YTDLP_NODE }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        'C:\Program Files\nodejs\node.exe',
        'C:\Program Files (x86)\nodejs\node.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        'D:\tools\node\node.exe'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

# ------------------------------------------------------------- detect proxy mode
function Test-Proxy {
    param([int]$Port)
    if ($Port -le 0) { return $false }
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1200, $false)
        if ($ok -and $tcp.Connected) { $tcp.Close(); return $true }
        $tcp.Close()
    } catch { }
    return $false
}

$useProxy = Test-Proxy -Port $ProxyPort
$proxyUrl = "http://127.0.0.1:$ProxyPort"

# --------------------------------------------------------------- cookie handling
function Export-Cookies {
    param([string]$Py, [string]$BrowserName, [string]$Jar)
    $helper = Join-Path $Root 'scripts\export-cookies.py'
    if (-not (Test-Path $helper)) { throw "export-cookies.py missing under scripts\" }
    Write-Host "Exporting cookies from $BrowserName ..." -ForegroundColor Cyan
    # No --proxy here: cookies are read from the local browser DB, not the network.
    & $Py $helper --browser $BrowserName --out $Jar
    if ($LASTEXITCODE -ne 0) {
        throw @"
Cookie export failed.
  * Close $BrowserName completely (it locks the cookie DB) and retry.
  * Chrome 127+ may use app-bound encryption which cannot be decrypted from scripts;
    use Edge/Firefox instead, or update Chrome launch with --disable-features=AppBoundEncryption.
"@
    }
}

if ($Mode -eq 'cookies') {
    Export-Cookies -Py $script:ActivePython -BrowserName $Browser -Jar $CookieJar
    Write-Host "done: $CookieJar"
    return
}

if (-not $Url) { throw "-Url is required (or use -Mode cookies)" }

$hasCookies = Test-Path $CookieJar
if (-not $hasCookies) {
    Write-Host "No cookie jar yet - YouTube will likely refuse anonymous requests." -ForegroundColor Yellow
    Write-Host "Run:  .\yt-fetch.ps1 -Mode cookies" -ForegroundColor Yellow
}

# --------------------------------------------------------------- assemble flags
$ytArgs = @('--cache-dir', $CacheDir, '--no-warnings')

if ($useProxy) {
    $ytArgs += @('--proxy', $proxyUrl)
    Write-Host "mode: proxy $proxyUrl" -ForegroundColor DarkGray
} else {
    Write-Host "mode: direct (no local proxy on port $ProxyPort)" -ForegroundColor DarkGray
}

if ($hasCookies) { $ytArgs += @('--cookies', $CookieJar) }

$node = Find-Node
if ($node) {
    $ytArgs += @('--js-runtimes', "node:$node")
    # EJS solves YouTube's n-challenge; without it only image formats are exposed.
    $ytArgs += @('--remote-components', 'ejs:github')
    Write-Verbose "node: $node"
} else {
    Write-Host "warning: no Node.js found -some formats may be unavailable." -ForegroundColor Yellow
    Write-Host "         install Node.js, or set `$env:YTDLP_NODE" -ForegroundColor Yellow
}

# ------------------------------------------------------------------- run yt-dlp
switch ($Mode) {
    'info' {
        $ytArgs += @(
            '--skip-download',
            '--print', '%(title)s',
            '--print', 'author: %(uploader)s',
            '--print', 'duration_sec: %(duration)s',
            '--print', 'upload_date: %(upload_date)s',
            '--print', 'view_count: %(view_count)s',
            '--print', 'subtitles: %(subtitles.keys)s',
            '--print', 'autocaptions: %(automatic_captions.keys)s',
            $Url
        )
    }
    'subs' {
        $ytArgs += @(
            '--skip-download',
            '--write-subs', '--write-auto-subs',
            '--sub-langs', 'all',
            '--sub-format', 'json3/vtt/best',
            '--convert-subs', 'srt',
            '-o', (Join-Path $Out '%(id)s.%(ext)s'),
            $Url
        )
    }
    'audio' {
        if (-not $Format) { $Format = '140/bestaudio' }
        $ytArgs += @('-f', $Format, '-o', (Join-Path $Out '%(id)s.%(ext)s'), $Url)
    }
    'video' {
        if (-not $Format) { $Format = 'bv*[height<=720]+ba/b[height<=720]' }
        $ytArgs += @(
            '-f', $Format,
            '--merge-output-format', 'mp4',
            '-o', (Join-Path $Out '%(id)s.%(ext)s'),
            $Url
        )
    }
}

$env:PYTHONUTF8 = '1'
& $script:ActivePython -m yt_dlp @ytArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "If you saw 'Sign in to confirm you're not a bot':" -ForegroundColor Yellow
    Write-Host "  .\yt-fetch.ps1 -Mode cookies        # refresh cookies, then retry" -ForegroundColor Yellow
    exit $LASTEXITCODE
}

