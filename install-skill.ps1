<#
.SYNOPSIS
    Install the youtube-via-proxy skill into this machine's DSH skill library.

.DESCRIPTION
    Copies SKILL.md into ~/.agents/skills/youtube-via-proxy/ and rewrites the tool
    paths inside it so they point at wherever this package currently lives.
    Run from the package root.

.PARAMETER SkillDir
    Target skill library (default: ~/.agents/skills)

.EXAMPLE
    .\install-skill.ps1
#>
param(
    [string]$SkillDir = (Join-Path $env:USERPROFILE '.agents\skills')
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$target = Join-Path $SkillDir 'youtube-via-proxy'
New-Item -ItemType Directory -Force -Path $target | Out-Null

$src = Join-Path $here 'SKILL.md'
if (-not (Test-Path $src)) { throw "SKILL.md missing next to this script" }

# Point the skill at this package's absolute location.
$content = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
$content = $content.Replace('{{TOOL_DIR}}', $here)
[IO.File]::WriteAllText((Join-Path $target 'SKILL.md'), $content, (New-Object Text.UTF8Encoding($false)))

Write-Host "installed skill -> $(Join-Path $target 'SKILL.md')" -ForegroundColor Green
Write-Host "tool dir       -> $here"

# Quick sanity check: is the toolchain usable here?
Write-Host ""
Write-Host "checking prerequisites..." -ForegroundColor Cyan

$py = $null
$pyVersion = $null
foreach ($c in @('python', 'python3', 'py')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    # Skip the Windows Store shim in WindowsApps — it only prints an install advert.
    if ($cmd.Source -like '*WindowsApps*') { continue }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $v = & $cmd.Source -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>&1
        if ($LASTEXITCODE -eq 0 -and ($v -join '') -match '\d+\.\d+') {
            $py = $cmd.Source
            $pyVersion = ($v | Where-Object { $_ -match '^\d+\.\d+$' } | Select-Object -First 1)
            break
        }
    } catch { }
    finally { $ErrorActionPreference = $prev }
}
if ($py) {
    Write-Host "  python: $py ($pyVersion)" -ForegroundColor Green
} else {
    # Last resort: a python.exe in common install locations.
    $fallback = @(
        'C:\Python313\python.exe', 'C:\Python312\python.exe',
        'C:\Python311\python.exe', 'C:\Python310\python.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($fallback) {
        Write-Host "  python: $fallback (not on PATH)" -ForegroundColor Yellow
        Write-Host "          yt-fetch.ps1 can use it, but adding Python to PATH is easier." -ForegroundColor Yellow
    } else {
        Write-Host "  python: NOT FOUND - install from https://python.org" -ForegroundColor Red
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    Write-Host "  node  : $($node.Source)" -ForegroundColor Green
} else {
    Write-Host "  node  : not found (needed for AES-GCM cookie decrypt + yt-dlp n-challenge)" -ForegroundColor Yellow
}

$ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ff) {
    Write-Host "  ffmpeg: $($ff.Source)" -ForegroundColor Green
} else {
    Write-Host "  ffmpeg: not found (only needed for -Mode video / hard subtitles)" -ForegroundColor Yellow
}

$proxyUp = $false
try {
    $tcp = New-Object Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect('127.0.0.1', 10808, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(1200, $false) -and $tcp.Connected) { $proxyUp = $true }
    $tcp.Close()
} catch { }
Write-Host ("  proxy : 127.0.0.1:10808 " + $(if ($proxyUp) { 'UP' } else { 'not listening (direct mode will be used)' })) `
    -ForegroundColor $(if ($proxyUp) { 'Green' } else { 'Yellow' })

Write-Host ""
Write-Host "next: .\yt-fetch.ps1 -Mode cookies    # export browser cookies" -ForegroundColor Cyan
Write-Host "      .\yt-fetch.ps1 -Url <ID> -Mode info" -ForegroundColor Cyan
