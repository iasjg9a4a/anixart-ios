#!/usr/bin/env pwsh
# Синхронизирует текущую ветку с публичным CI-репозиторием и запускает проверки.
#
#   ./tools/ci_push.ps1                 # слить код и запустить build.yml (сборка+тесты+IPA)
#   ./tools/ci_push.ps1 -Screenshots    # дополнительно запустить screenshots.yml
#   ./tools/ci_push.ps1 -Release v0.1.5 # создать тег в CI-репозитории (release.yml соберёт IPA)
#
# Требует: gh CLI, авторизованные аккаунты (dev + CI) и токен CI-аккаунта.
param(
    [switch]$Screenshots,
    [string]$Release = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$ciRepo = "iasjg9a4a/anixart-ios"
$remote = "https://github.com/$ciRepo.git"

Write-Host "==> синхронизация в $ciRepo"
$env:MIRROR_TOKEN = (gh auth token --user iasjg9a4a)
if (-not $env:MIRROR_TOKEN) { throw "нет токена для iasjg9a4a (gh auth login)" }
python tools/mirror_to_ci.py --remote $remote --message ("CI mirror " + (git rev-parse --short HEAD))

$env:GH_TOKEN = $env:MIRROR_TOKEN

if ($Release) {
    Write-Host "==> тег $Release"
    git tag -f $Release
    git push -f "https://github.com/$ciRepo.git" "refs/tags/$Release" 2>$null
    gh workflow run release.yml --repo $ciRepo --ref main
} else {
    Write-Host "==> запуск build.yml"
    gh workflow run build.yml --repo $ciRepo --ref main
}

if ($Screenshots) {
    Write-Host "==> запуск screenshots.yml"
    Start-Sleep -Seconds 3
    gh workflow run screenshots.yml --repo $ciRepo --ref main
}

Write-Host "==> ждём завершения запусков"
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 15
    $runs = gh run list --repo $ciRepo --limit 3 --json databaseId,status,conclusion,displayTitle | ConvertFrom-Json
    if (-not $runs) { continue }
    $pending = $runs | Where-Object { $_.status -ne "completed" }
    if (-not $pending) {
        $runs | ForEach-Object { "{0,-60} {1}" -f $_.displayTitle.Substring(0, [Math]::Min(60, $_.displayTitle.Length)), $_.conclusion }
        break
    }
}

Write-Host "==> артефакты (последние запуски)"
gh run list --repo $ciRepo --limit 5
