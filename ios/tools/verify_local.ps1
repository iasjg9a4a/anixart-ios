#requires -Version 5.1
<#
.SYNOPSIS
    One-shot локальная проверка iOS-клиента Anixart без macOS и без CI.

.DESCRIPTION
    Последовательно запускает доступные на Windows уровни проверки из
    docs/LOCAL_VERIFICATION.md (через Compiler Explorer, локальный Swift не нужен):

      1. tools/api_probe.py                 — живой контракт API (13 проверок)
      2. tools/StubSwiftUI/check.py all     — typecheck всего приложения по заглушке SwiftUI
      3. tools/fetch_fixtures.py            — обновить реальные фикстуры API
                                              (без сети шаг пропускается)
      4. tools/linux_tests.py               — исполнить 68 юнит-тестов на CE (Swift 6.4.2 Linux)

    Печатает сводную таблицу по шагам и возвращает 0 только если все выполненные
    шаги прошли. Любой FAIL или непроверенный сетевой шаг (нет сети до godbolt.org /
    api-s.anixsekai.com) — код возврата 1: пропуск не считается «зелёным».

    Блоки, которые может проверить только macOS/Xcode (сборка под iOS SDK,
    UI-тесты, Keychain/AVFoundation рантайм), этим скриптом не проверяются.

.PARAMETER SkipFixtures
    Не запускать fetch_fixtures.py (не трогать закоммиченные фикстуры).

.PARAMETER CeDelay
    Пауза между запросами к Compiler Explorer, секунды (по умолчанию 1.0).
    Если CE отвечает 429, tools/linux_tests.py сам делает повтор с backoff.

.EXAMPLE
    cd ios
    pwsh -File tools/verify_local.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/verify_local.ps1 -SkipFixtures -CeDelay 2
#>
[CmdletBinding()]
param(
    [switch]$SkipFixtures,
    [double]$CeDelay = 1.0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

# --- пути: скрипт лежит в <repo>/ios/tools, работать нужно из <repo>/ios ---
$IosRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $IosRoot 'tools\linux_tests.py'))) {
    Write-Host "Не найден ios/tools/linux_tests.py рядом со скриптом: $IosRoot" -ForegroundColor Red
    exit 1
}

# --- UTF-8, иначе python-скрипты падают на кириллице/стрелках в cp1251-консоли ---
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:PYTHONUNBUFFERED = '1'   # иначе python буферизует вывод при перенаправлении в Tee-Object

# --- python: python / python3 / py ---
$Python = $null
foreach ($candidate in @('python', 'python3', 'py')) {
    $found = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Python = $found.Source; break }
}
if (-not $Python) {
    Write-Host 'Python не найден в PATH. Нужен Python 3.8+ (проверьте python --version).' -ForegroundColor Red
    exit 1
}

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir = Join-Path $env:TEMP "anixart-verify-$Stamp"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$script:Python = $Python
$script:Results = New-Object System.Collections.ArrayList

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutMs = 4000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Add-Result {
    param(
        [string]$Step,
        [string]$Status,   # PASS / FAIL / SKIP
        [double]$Seconds,
        [string]$Note = ''
    )
    [void]$script:Results.Add([pscustomobject]@{
        Step    = $Step
        Status  = $Status
        Seconds = [math]::Round($Seconds, 1)
        Note    = $Note
    })
}

# Запускает python-скрипт из корня ios/, стримит вывод в консоль и в лог-файл.
# $FailMarkers — подстроки, которые ловят «тихий» провал (например, check.py
# возвращает 0, даже когда CE недоступен: печатает "CE request failed").
function Invoke-PythonStep {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @(),
        [string[]]$FailMarkers = @()
    )
    Write-Host ''
    Write-Host ("===== {0} =====" -f $Title) -ForegroundColor Cyan
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    Write-Host ("  {0} {1} {2}" -f $script:Python, $Script, ($quoted -join ' ')) -ForegroundColor DarkGray

    $logPath = Join-Path $LogDir (($Title -replace '[^\w\.\-]+', '_') + '.log')
    $started = Get-Date
    & $script:Python $Script @Arguments 2>&1 | Tee-Object -FilePath $logPath | Out-Host
    $exitCode = $LASTEXITCODE
    $seconds = ((Get-Date) - $started).TotalSeconds

    $status = 'PASS'
    $note = ''
    if ($exitCode -ne 0) {
        $status = 'FAIL'
        $note = "exit code $exitCode"
    }
    if ($FailMarkers.Count -gt 0 -and (Test-Path -LiteralPath $logPath)) {
        $content = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
        foreach ($marker in $FailMarkers) {
            if ($content -and $content -match [regex]::Escape($marker)) {
                $status = 'FAIL'
                $note = "в выводе: $marker"
            }
        }
    }
    if ($status -eq 'PASS') { $note = 'ok' }
    Add-Result -Step $Title -Status $status -Seconds $seconds -Note $note
    return $status
}

function Add-Skipped {
    param([string]$Step, [string]$Why, [bool]$CountsAsFailure)
    Write-Host ''
    Write-Host ("===== {0} =====" -f $Step) -ForegroundColor DarkYellow
    Write-Host ("  SKIP: {0}" -f $Why) -ForegroundColor Yellow
    Add-Result -Step $Step -Status 'SKIP' -Seconds 0 -Note $Why
    return $CountsAsFailure
}

# --------------------------------------------------------------------------- #
# Шапка
# --------------------------------------------------------------------------- #
$startedAll = Get-Date
Push-Location -LiteralPath $IosRoot
try {
    Write-Host ''
    Write-Host 'Anixart iOS — локальная проверка без macOS (Compiler Explorer, Swift 6.4.2 Linux)' -ForegroundColor Green
    Write-Host ("Каталог: {0}" -f $IosRoot) -ForegroundColor DarkGray
    Write-Host ("Python:  {0}" -f (& $script:Python --version 2>&1)) -ForegroundColor DarkGray
    Write-Host ("Логи:    {0}" -f $LogDir) -ForegroundColor DarkGray

    # Сеть нужна трём шагам из четырёх; проверяем отдельно, чтобы не ждать таймаутов.
    Write-Host ''
    Write-Host 'Проверка сети (4 с на хост)...' -ForegroundColor DarkGray
    $apiOnline = Test-TcpPort -HostName 'api-s.anixsekai.com' -Port 443
    $ceOnline = Test-TcpPort -HostName 'godbolt.org' -Port 443
    Write-Host ("  api-s.anixsekai.com: {0}" -f $(if ($apiOnline) { 'доступен' } else { 'НЕДОСТУПЕН' }))
    Write-Host ("  godbolt.org:         {0}" -f $(if ($ceOnline) { 'доступен' } else { 'НЕДОСТУПЕН' }))

    $failed = 0
    $skippedRequired = 0

    # 1. Живой контракт API.
    if ($apiOnline) {
        $s = Invoke-PythonStep -Title '1/4 api_probe.py' -Script 'tools/api_probe.py'
    } else {
        $s = 'SKIP'
        Add-Skipped -Step '1/4 api_probe.py' -Why 'нет сети до api-s.anixsekai.com' -CountsAsFailure $true | Out-Null
        $skippedRequired++
    }
    if ($s -eq 'FAIL') { $failed++ }

    # 2. Typecheck всего приложения по заглушке SwiftUI (CE).
    if ($ceOnline) {
        $s = Invoke-PythonStep -Title '2/4 StubSwiftUI/check.py all' `
            -Script 'tools/StubSwiftUI/check.py' -Arguments @('all') `
            -FailMarkers @('CE request failed')
    } else {
        $s = 'SKIP'
        Add-Skipped -Step '2/4 StubSwiftUI/check.py all' -Why 'нет сети до godbolt.org' -CountsAsFailure $true | Out-Null
        $skippedRequired++
    }
    if ($s -eq 'FAIL') { $failed++ }

    # 3. Фикстуры: без сети шаг пропускается (фикстуры остаются прежними).
    if ($SkipFixtures) {
        Add-Skipped -Step '3/4 fetch_fixtures.py' -Why 'пропущен: -SkipFixtures' -CountsAsFailure $false | Out-Null
    } elseif ($apiOnline) {
        $s = Invoke-PythonStep -Title '3/4 fetch_fixtures.py' -Script 'tools/fetch_fixtures.py'
        if ($s -eq 'FAIL') { $failed++ }
    } else {
        Add-Skipped -Step '3/4 fetch_fixtures.py' -Why 'пропущен: нет сети до api-s.anixsekai.com' -CountsAsFailure $false | Out-Null
    }

    # 4. 68 юнит-тестов на Linux через CE (главный шаг).
    if ($ceOnline) {
        $reportPath = Join-Path $LogDir 'linux_tests_report.json'
        $ltArgs = @('--json', $reportPath)
        $ltArgs += @('--delay', $CeDelay.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        $s = Invoke-PythonStep -Title '4/4 linux_tests.py' -Script 'tools/linux_tests.py' -Arguments $ltArgs
        if ($s -eq 'FAIL') { $failed++ }
    } else {
        Add-Skipped -Step '4/4 linux_tests.py' -Why 'нет сети до godbolt.org' -CountsAsFailure $true | Out-Null
        $skippedRequired++
    }
    $totalSeconds = ((Get-Date) - $startedAll).TotalSeconds

    # ----------------------------------------------------------------------- #
    # Сводка
    # ----------------------------------------------------------------------- #
    Write-Host ''
    Write-Host '===== СВОДКА =====' -ForegroundColor Cyan
    $table = $script:Results | Format-Table -AutoSize Step, Status, Seconds, Note | Out-String -Width 200
    Write-Host $table.TrimEnd()

    $passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skipCount = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count
    # Явный InvariantCulture + стандартный формат F1: на ru-RU кастомный "0.1"
    # в этом .NET даёт склеенное число без разделителя (21.2 -> "211").
    $totalText = $totalSeconds.ToString('F1', [System.Globalization.CultureInfo]::InvariantCulture)
    Write-Host ("PASS: {0}   FAIL: {1}   SKIP: {2}   всего: {3} с" -f $passCount, $failCount, $skipCount, $totalText)
    Write-Host ("Полные логи: {0}" -f $LogDir) -ForegroundColor DarkGray

    if ($failed -gt 0) {
        Write-Host 'ИТОГ: ПРОВАЛ — см. FAIL-шаги выше.' -ForegroundColor Red
        exit 1
    }
    if ($skippedRequired -gt 0) {
        Write-Host ('ИТОГ: НЕ ПРОВЕРЕНО — {0} сетевой(ых) шаг(а) пропущены (нет сети). ' -f $skippedRequired +
                   'Это не «зелёный» прогон.') -ForegroundColor Red
        exit 1
    }
    Write-Host 'ИТОГ: OK — все выполненные шаги прошли.' -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
