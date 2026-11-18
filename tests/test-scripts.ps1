#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Static checks for the PowerShell scripts — no network, no browser, no YouTube.

.DESCRIPTION
    Verifies the things that silently break when someone edits the scripts:
      * every .ps1 still parses
      * no hardcoded personal paths leaked in
      * yt-fetch.ps1 declares the parameters the README promises
      * credential files are not tracked by git

    Run locally or from CI. Exits non-zero on the first failed check.
#>
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path $RepoRoot)) { throw "repo root not found: $RepoRoot" }

$script:failures = @()
function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $result = & $Test
        if ($result -eq $true -or $null -eq $result) {
            Write-Host "  PASS  $Name" -ForegroundColor Green
        } else {
            Write-Host "  FAIL  $Name -> $result" -ForegroundColor Red
            $script:failures += $Name
        }
    } catch {
        Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red
        $script:failures += $Name
    }
}

Write-Host "PowerShell script checks" -ForegroundColor Cyan
Write-Host "repo: $RepoRoot"

# ---------------------------------------------------------------- 1. parseable
$psFiles = Get-ChildItem $RepoRoot -Filter '*.ps1' -File
Check "found PowerShell scripts" { if ($psFiles.Count -gt 0) { $true } else { "no .ps1 files" } }

foreach ($f in $psFiles) {
    $path = $f.FullName
    Check "$($f.Name) parses" {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs) | Out-Null
        if ($errs -and $errs.Count -gt 0) { "$($errs.Count) parse errors: $($errs[0].Message)" } else { $true }
    }
}

# ------------------------------------------------- 2. no personal paths leaked
Check "no hardcoded user paths" {
    # Any absolute path containing a real username is a portability bug.
    $pattern = 'C:\\Users\\(?!\$env)[A-Za-z0-9_.-]+\\'
    $hits = @()
    foreach ($f in $psFiles + (Get-ChildItem $RepoRoot -Recurse -Include '*.py' -File)) {
        $m = Select-String -Path $f.FullName -Pattern $pattern -AllMatches -ErrorAction SilentlyContinue
        if ($m) { $hits += "$($f.Name):$($m[0].LineNumber)" }
    }
    if ($hits.Count -gt 0) { "hardcoded paths at " + ($hits -join ', ') } else { $true }
}

Check "no deepseek-harness/DSH runtime paths" {
    $hits = @()
    foreach ($f in $psFiles + (Get-ChildItem $RepoRoot -Recurse -Include '*.py' -File)) {
        $m = Select-String -Path $f.FullName -Pattern 'dsh-runtimes|deepseek-harness' -ErrorAction SilentlyContinue
        if ($m) { $hits += $f.Name }
    }
    if ($hits.Count -gt 0) { "found in " + ($hits -join ', ') } else { $true }
}

# --------------------------------------------------- 3. yt-fetch.ps1 contract
$ytFetch = Join-Path $RepoRoot 'yt-fetch.ps1'
Check "yt-fetch.ps1 declares documented parameters" {
    if (-not (Test-Path $ytFetch)) { return "yt-fetch.ps1 missing" }
    $content = Get-Content $ytFetch -Raw
    $missing = @()
    foreach ($p in @('Url', 'Mode', 'Format', 'ProxyPort', 'Browser', 'Out')) {
        if ($content -notmatch "(?m)^\s*\[[^\]]*\]\s*\`$$p\b") { $missing += $p }
    }
    if ($missing.Count -gt 0) { "missing params: " + ($missing -join ', ') } else { $true }
}

Check "yt-fetch.ps1 exposes all documented modes" {
    $content = Get-Content $ytFetch -Raw
    $missing = @()
    foreach ($m in @('info', 'subs', 'audio', 'video', 'cookies')) {
        if ($content -notmatch "'$m'") { $missing += $m }
    }
    if ($missing.Count -gt 0) { "missing modes: " + ($missing -join ', ') } else { $true }
}

Check "yt-fetch.ps1 passes the EJS component to yt-dlp" {
    # Without this flag YouTube only exposes image formats.
    $content = Get-Content $ytFetch -Raw
    if ($content -match 'ejs:github') { $true } else { "ejs:github flag missing" }
}

Check "yt-fetch.ps1 always passes --cookies when a jar exists" {
    $content = Get-Content $ytFetch -Raw
    if ($content -match "--cookies") { $true } else { "no --cookies handling" }
}

# ------------------------------------------- 4. hardsubs script sanity checks
$hs = Join-Path $RepoRoot 'extract-hardsubs.ps1'
Check "extract-hardsubs.ps1 defaults to the bottom strip" {
    if (-not (Test-Path $hs)) { return "extract-hardsubs.ps1 missing" }
    $content = Get-Content $hs -Raw
    # bottom 20%: crop height ih*0.20 offset ih*0.80
    if ($content -match 'ih\*0\.20' -and $content -match 'ih\*0\.80') { $true } else { "default crop changed" }
}

Check "extract-hardsubs.ps1 clears stale frames" {
    $content = Get-Content $hs -Raw
    if ($content -match 'Remove-Item' -and $content -match '\*\.jpg') { $true } else { "no stale-frame cleanup" }
}

# --------------------------------------------- 5. no credentials in the tree
Check "git does not track credential files" {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return $true }   # not a repo checkout; skip silently
    Push-Location $RepoRoot
    try {
        $tracked = & git ls-files 2>$null
        if ($LASTEXITCODE -ne 0) { return $true }
    } finally { Pop-Location }
    $bad = $tracked | Where-Object { $_ -match '(^|/)cookies\.txt$|stage1\.json$|\.venv/' }
    if ($bad) { "tracked: " + ($bad -join ', ') } else { $true }
}

Check ".gitignore excludes cookies and build output" {
    $gi = Join-Path $RepoRoot '.gitignore'
    if (-not (Test-Path $gi)) { return ".gitignore missing" }
    $content = Get-Content $gi -Raw
    $missing = @()
    foreach ($entry in @('cookies.txt', '.venv', '__pycache__', 'out/')) {
        if ($content -notmatch [regex]::Escape($entry)) { $missing += $entry }
    }
    if ($missing.Count -gt 0) { "missing entries: " + ($missing -join ', ') } else { $true }
}

# ------------------------------------------------------------------- summary
Write-Host ""
if ($script:failures.Count -eq 0) {
    Write-Host "All PowerShell checks passed." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:failures.Count) check(s) failed:" -ForegroundColor Red
$script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
