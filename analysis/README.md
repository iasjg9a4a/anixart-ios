# Материалы разбора APK

Всё в этой папке получено из `../anixart_11-beta-3.apk` и живых запросов к API.

| Файл / папка | Что это |
|---|---|
| `endpoints.txt` | 319 путей API, вытащенных из строк `classes*.dex` и сгруппированных по ресурсу |
| `unpacked/classes*.dex` | 4 dex-файла (распакованы из APK, ~24 МБ) |
| `unpacked/AndroidManifest.xml` | бинарный манифест (активности, сервисы, права) |
| `unpacked/resources.arsc` | таблица ресурсов |
| `unpacked/assets/` | HTML-плееры (`player_default.html`, `player_youtube.html`, `no_connection.html`) |
| `strings.txt` | все ASCII-строки из dex (4,8 МБ) — удобно грепать |
| `fixtures/` | реальные JSON-ответы API, снятые 21.11.2026 |

## Как это воспроизвести

```powershell
# распаковать нужное из APK
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead("..\anixart_11-beta-3.apk")
$zip.Entries | Where-Object { $_.FullName -match '^classes\d*\.dex$' } | ForEach-Object {
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, "unpacked\$($_.Name)", $true)
}
$zip.Dispose()
```

Пути API ищутся так: строки dex имеют префикс длины, поэтому регулярка вида
`[a-z][a-zA-Z0-9]*(/[a-zA-Z0-9_{}]+)+` по сырым байтам даёт пути без ведущего `/`,
а первый байт иногда «прилипает» к строке — отсюда варианты с обрезанной первой буквой.

## Полезные факты

* Пакет: `com.swiftsoft.anixartd`, приложение нативное (Kotlin + Compose), общего кода с iOS нет.
* Хост API: `https://api-s.anixsekai.com/`.
* Поиск — `POST search/releases/{page}` с телом `{"query": "..."}` (GET отвечает 400).
* `episode/target/{releaseId}/{sourceId}/{position}` отдаёт подписанный URL плеера
  **без авторизации**; `episode/watch/...` (отметка просмотра) — требует токен.
* `auth/signIn` принимает **только** `application/x-www-form-urlencoded`
  (`login=…&password=…`); на JSON-тело отвечает `200` с пустым телом. Подписей, device-id и
  капчи в логине нет — проверено 24.11.2026. Коды: 0 — успех, 2 — невалидный логин,
  3 — неверная пара.
