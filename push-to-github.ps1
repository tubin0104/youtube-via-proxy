# push-to-github.ps1 —— 把本地仓库推到 GitHub
# 用法 A（有 token，自动建仓库）：
#   .\push-to-github.ps1 -Token <你的PAT> -RepoName youtube-via-proxy
# 用法 B（仓库已存在）：
#   .\push-to-github.ps1 -RemoteUrl https://github.com/<user>/<repo>.git
param(
    [string]$Token = '',
    [string]$RepoName = 'youtube-via-proxy',
    [string]$RemoteUrl = '',
    [switch]$Private
)

$ErrorActionPreference = 'Stop'
$env:PATH = "D:\tools\git\cmd;" + $env:PATH

$RepoDir = Split-Path -Parent $PSScriptRoot

if ($Token) {
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    Write-Host "读取 GitHub 账号..." -ForegroundColor Cyan
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers
    $user = $me.login
    Write-Host "  账号: $user"

    $body = @{
        name        = $RepoName
        description = 'Read YouTube videos from scripts and AI agents: metadata, subtitles, audio, video, and burned-in subtitles'
        private     = [bool]$Private
        has_issues  = $true
    } | ConvertTo-Json

    Write-Host "创建仓库 $user/$RepoName ..." -ForegroundColor Cyan
    try {
        $repo = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post `
            -Headers $headers -Body $body -ContentType 'application/json'
        Write-Host "  已创建: $($repo.html_url)" -ForegroundColor Green
    } catch {
        $msg = $_.ErrorDetails.Message
        if ($msg -match 'already exists') {
            Write-Host "  仓库已存在，直接推送" -ForegroundColor Yellow
        } else {
            throw "创建仓库失败: $msg"
        }
    }
    $RemoteUrl = "https://$user`:$Token@github.com/$user/$RepoName.git"
} elseif (-not $RemoteUrl) {
    throw "必须提供 -Token（自动建仓库）或 -RemoteUrl（推送到已有仓库）"
}

Push-Location $RepoDir
try {
    & git remote remove origin 2>$null
    & git remote add origin $RemoteUrl
    & git branch -M main
    Write-Host "推送中..." -ForegroundColor Cyan
    & git push -u origin main
    if ($LASTEXITCODE -ne 0) { throw "push 失败（检查 token 权限是否含 repo）" }
} finally { Pop-Location }

# 推完立刻把带 token 的 remote 改回干净地址，避免留在 .git/config
$clean = $RemoteUrl -replace 'https://[^@]+@', 'https://'
Push-Location $RepoDir
& git remote set-url origin $clean
Pop-Location

Write-Host ""
Write-Host "完成: $clean" -ForegroundColor Green
