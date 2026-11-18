#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Extract burned-in ("hard") subtitles from a video by sampling the bottom strip.

.DESCRIPTION
    Many Chinese-language tech channels don't publish caption tracks at all; the
    narration is burned into the picture instead. yt-dlp then reports "has no
    subtitles", and the only way to read the talk is to OCR the bottom strip.

    This script samples one frame every N seconds, crops the subtitle strip, and
    upscales it so a vision model can read the text. You then read the produced
    images in filename order and reconstruct the narration.

.PARAMETER Video
    Source video file.

.PARAMETER Interval
    Seconds between sampled frames (default 12).

.PARAMETER Crop
    FFmpeg crop expression for the strip. Default samples the bottom 20%:
    "iw:ih*0.20:0:ih*0.80"

.PARAMETER Scale
    Upscale width so small text stays legible (default 1280).

.PARAMETER Out
    Output directory (default: <video dir>/subsamples)

.EXAMPLE
    .\extract-hardsubs.ps1 -Video .\out\TI66H3VDE3Y.mp4 -Interval 12

.EXAMPLE
    # text sits higher up (e.g. centered overlay)
    .\extract-hardsubs.ps1 -Video .\out\x.mp4 -Crop "iw:ih*0.10:0:ih*0.62"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Video,

    [int]$Interval = 12,

    [string]$Crop = '',

    [int]$Scale = 1280,

    [string]$Out = '',

    [string]$Ffmpeg = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Video)) { throw "video not found: $Video" }

if (-not $Ffmpeg) {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $Ffmpeg = $cmd.Source }
    elseif (Test-Path 'D:\tools\ffmpeg\bin\ffmpeg.exe') { $Ffmpeg = 'D:\tools\ffmpeg\bin\ffmpeg.exe' }
    else {
        throw @"
ffmpeg not found. Install it (winget install Gyan.FFmpeg) or pass -Ffmpeg <path>.
"@
    }
}

if (-not $Out) { $Out = Join-Path (Split-Path -Parent (Resolve-Path $Video)) 'subsamples' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -Filter '*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force

# Bottom 20% by default — where burned-in subtitles almost always sit.
if (-not $Crop) { $Crop = 'iw:ih*0.20:0:ih*0.80' }

$vf = "fps=1/$Interval,crop=$Crop,scale=$Scale`:-1"

Write-Host "sampling every ${Interval}s"
Write-Host "crop: $Crop"
Write-Host "out : $Out"

& $Ffmpeg -hide_banner -loglevel error -y -i $Video -vf $vf -q:v 2 (Join-Path $Out 's%04d.jpg')
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed" }

$files = Get-ChildItem $Out -Filter '*.jpg' | Sort-Object Name
Write-Host ("produced {0} strips" -f $files.Count)
Write-Host "index N corresponds to t = (N-1) * $Interval seconds"
