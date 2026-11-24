# Офлайн-скачивание серий: что реально скачать и как это делать на iOS

Короткий ответ: **скачать можно не всё, но для Libria/Liberty, RuTube и AnixPlayer/StudioMir
это реально** — все три отдают HLS-плейлисты, проверенные живыми запросами и открывающиеся
без cookies/Referer. **Kodik скачать нельзя** (прямая ссылка — `500`, только iframe-прокси).
**Sibnet** — под вопросом: видео-хост с нашей сети отвечает `403`, цепочка не проверена.

Документ — результат разбора API, Android-оригинала (`analysis/unpacked/classes*.dex`) и живых
проб 24.11.2026 (Python 3.10, IP `178.208.227.243` — он же зашит в подписи `episode/target`).
**На iOS-устройстве ничего из AVFoundation не проверялось** — это этап 0 плана.
## Что реально скачать
### API не отдаёт файл, только подписанную страницу плеера
`GET https://api-s.anixsekai.com/episode/target/{releaseId}/{sourceId}/{position}` возвращает
`{code, episode{url, iframe, quality, …}}`, где `url` — подписанная ссылка на **плеер**
(`d`, `s`, `ip`), а не медиафайл. Живые примеры:

| Релиз | Источник | `url` (сокращённо) | `iframe` |
|---|---|---|---|
| 1 | Kodik | `https://kodikplayer.com/seria/175268/<hash>/720p?d=2026112405&s=…&ip=…` | `true` |
| 1562 | Libria | `https://anixart.libria.fun/public/iframe.php?id=1243&ep=1&d=…&s=…&ip=…` | `false` |
| 1562 | Sibnet | `https://video.sibnet.ru/shell.php?videoid=2665039&d=…&s=…&ip=…` | `false` |
| 5 | Sibnet | `{"code":1,"episode":null}`: у источника `episodes_count: 0`, серий нет | — |

Режим `GET …?download=true` (`downloadTarget` в
[`anixapi-ref/src/api/release/episode.ts`](../../anixapi-ref/src/api/release/episode.ts)),
вопреки названию, **прямую ссылку на файл не даёт**: `episode.url`/`iframe` не меняются,
меняется подпись `s`, а в корне ответа появляется `download_speed_limit`. Живые ответы
(`code`/`download_speed_limit`): Kodik `1/8/1` — `0`/`0`, Sibnet `1562/1/1` — `0`/`0`,
Libria `1562/218/1` — `0`/**`512`**, Liberty `20306/413/1` — `0`/**`512`**. Тот же
`download_speed_limit` и `is_download_disabled` есть в списке источников
(`episode/{r}/{typeId}` → `sources[]`): в выборке `0`/`false` у Kodik/Sibnet, `512` у
Libria/Liberty. SDK и dex документируют коды `DOWNLOAD_RESTRICTED = 2` и
`DOWNLOAD_SOURCE_RESTRICTED = 3` (Android: `EpisodeTargetResponse.isDownloadRestricted()` /
`isDownloadSourceRestricted()`), но **в живых запросах они не встретились** — все ответы
`code:0`. Единица измерения `download_speed_limit` не документирована; `512` похоже на КБ/с
(Android-`EpisodeFileDownloader` применяет свой `SpeedLimiter`), но это **не проверено**.

### Прямые медиа-ссылки появляются после резолверов
iOS-резолверы уже превращают страницы плееров в прямые HLS/MP4
(`ios/Anixart/Features/Player/`), и именно эти URL можно скачивать:

* **Libria/Liberty** — [`AniLibriaResolver.swift`](../ios/Anixart/Features/Player/AniLibriaResolver.swift):
  API `anilibria.top/api/v1/anime/releases/{id}` → `hls_1080/720/480`
  (`cache-rfn.libria.fun/...m3u8`). Живьём `hls_720` релиза 1243 — **media-плейлист**
  (не master), 145 сегментов `.ts`, 1450 с, `#EXT-X-ENDLIST`, без `#EXT-X-KEY`; плейлист и
  сегмент отдаются `200`/`206` **без Referer и cookies** (сегмент — через 302 на
  `cache1.cache-ru3.libria.fun` с одноразовым `expires` ~17 с — нормальный редирект CDN).
* **RuTube** — [`RutubeResolver.swift`](../ios/Anixart/Features/Player/RutubeResolver.swift):
  `play/options` → master `bl.rutube.ru/route/...m3u8?sign=…&expire=…` → child на
  `rtbcdn.ru`/`river-1.rutube.ru`. Живьём: master `200`, 12 вариантов (144p…1080p,
  `BANDWIDTH` 187000…2578000), child — VOD, 355 `.ts`-сегментов, 1415.7 с; всё без Referer,
  сегмент `206 video/MP2T`, без ключей. `expire` master — **≈ 24 ч**, метка в пути
  сегментов — **≈ 7 суток**.
* **AnixPlayer/StudioMir** — [`AnixPlayerResolver.swift`](../ios/Anixart/Features/Player/AnixPlayerResolver.swift):
  `api?ani=…&apikey=…` → `players.tsm[]` → `hls.1080p/720p` на `hokage-alt.studiomir.club`.
  Живьём (ani=1/2/10/53): TV-серии `200`, media-плейлист с `#EXT-X-ENDLIST`, `.ts`-сегменты
  `206`, Referer не нужен; часть TR-ссылок (`ani=1,2`) — `404`, то есть ссылка из ответа
  может быть мёртвой и требует проверки перед скачиванием.
* **Sibnet** — [`SibnetResolver.swift`](../ios/Anixart/Features/Player/SibnetResolver.swift):
  `shell.php` → regex `src:` → редирект на **прогрессивный MP4**. Живьём `shell.php` отвечал
  `403 Request forbidden by administrative rules` при всех UA/Referer (как в
  `docs/PLAYERS.md` §3) — форма `src:` и итоговый MP4 **не проверены**.
* **Kodik** — `PlaybackResolver` отправляет его только в `WKWebView` через
  `https://anixmirai.com/iframe?url=…`. Прямой `GET` подписанной ссылки — `500` при четырёх
  наборах заголовков (UA, Referer Kodik/Anixmirai); прокси — `200 text/html` с iframe.
  Файла/плейлиста наружу нет — скачивать нечего.

### Сколько занимает одна серия
Оценки по размерам сегментов (выборка 3–6 штук) и `BANDWIDTH` master-плейлиста:

| Источник | 480p | 720p | 1080p |
|---|---|---|---|
| Libria (1450 с) | — | ≈ 260 МБ (замер по сегментам) | — |
| RuTube (1415.7 с) | ≈ 147 МБ | ≈ 223 МБ | ≈ 456 МБ |
| StudioMir (1363–1422 с) | — | ≈ 320–355 МБ | ≈ 730–920 МБ |

«100–300 МБ за серию» верно для 480–720p; 1080p — 0,5–0,9 ГБ, для 64-ГБ iPhone это существенно.

### Оригинальный Android: как сделано и что из этого следует
В APK 11 BETA 3 есть своя подсистема загрузок (не Media3-offline): `EpisodeDownload` (Room;
`status`, `format`, `quality`, `maxHeight`, `downloadedBytes`, `totalBytes`,
`segmentIndex/segmentCount`, `filePath`, `error`; форматы `FORMAT_HLS_TS/HLS_FMP4/PROGRESSIVE`),
`EpisodeLinkResolver` (вызывает `EpisodeApi.episodeDownloadTarget`, затем те же `Parser`-классы,
что и для просмотра, достаёт прямые URL), `EpisodeFileDownloader` (OkHttp: HLS-сегменты,
`Range`-докачка, `BYTERANGE`, AES-128 через `#EXT-X-KEY`, лимит скорости; `401/403/404/410`
→ `LinkExpiredException` и повторный резолв), `EpisodeDownloads` (очередь, пауза, wifi-only,
уведомления, `/Download/Anixart/`), UI `DownloadsFragment`/`DownloadsReleaseFragment`.
Доступность скачивания — `EpisodeDownloadSourcesKt`: проверяются `source.isDownloadDisabled`
и хост `episode.url`; **Kodik в список разрешённых хостов не входит** (его хосты лежат
в отдельном массиве `Parser.l11l1lIl`, который эта проверка не смотрит), а Sibnet, Libria,
StudioMir, RuTube, VK, OK, MailRu, Myvi, Allvideo, SovetRomantica — входят.
Вывод: `?download=true` — это «разрешение + лимит скорости», а файл клиент добывает сам; на iOS эту роль играют `AVAssetDownloadURLSession` (HLS) и `URLSession` (MP4).

## Как (AVAssetDownloadURLSession пошагово)
`AVAssetDownloadURLSession` создаётся только с **background**-конфигурацией и переживает
сворачивание/перезапуск (система качает вне процесса); при force-quit загрузки отменяются.
Скачивается **только VOD** HLS; для прогрессивного MP4 (Sibnet) API не подходит.
Доки: [AVAssetDownloadURLSession](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession),
[AVAssetDownloadConfiguration](https://developer.apple.com/documentation/avfoundation/avassetdownloadconfiguration),
[сэмпл Apple](https://developer.apple.com/documentation/avfoundation/using-avfoundation-to-play-and-persist-http-live-streams).

1. **API-слой.** Добавить в `APIClient.episodeTarget` параметр `download: Bool`
   (`?download=true`) и `downloadSpeedLimit` в `EpisodeTargetResponse`
   ([Models.swift:645](../ios/Anixart/Models/Models.swift)); в `EpisodeSource` —
   `isDownloadDisabled`/`downloadSpeedLimit` ([Models.swift:415](../ios/Anixart/Models/Models.swift)).
   По ним блокировать кнопку и показывать ограничение скорости.
2. **Прямой URL.** Переиспользовать `AniLibriaResolver`/`RutubeResolver`/`AnixPlayerResolver`.
   Для Libria/StudioMir выбирается `hls_720`/`hls_1080` и т.п. — media-плейлисты, AVFoundation
   скачает один вариант. Для RuTube выгоднее отдавать master (`bl.rutube.ru/route/...m3u8`),
   чтобы качество выбрал `AVAssetVariantQualifier`; сейчас `RutubeResolver` возвращает уже
   выбранный вариант, поэтому нужен отдельный `downloadURL` (не ломая воспроизведение).
3. **Сессия.** Один `AVAssetDownloadURLSession` на приложение:

```swift
let config = URLSessionConfiguration.background(withIdentifier: "com.swiftsoft.anixart.downloads")
config.isDiscretionary = false   // старт только по явному действию
downloadSession = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: manager,
                                            delegateQueue: .main)
```

   Идентификатор должен быть один и тот же: при перезапуске приложение обязано пересоздать
   сессию с этим identifier, чтобы получить колбэки (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`).
4. **Задача.** Одна задача = один вариант качества:

```swift
let asset = AVURLAsset(url: hlsURL)   // hlsURL — media-плейлист или master
let configuration = AVAssetDownloadConfiguration(asset: asset, title: "Release — серия 1")
if let master = masterURL {                                     // только RuTube
    configuration.primaryContentConfiguration.variantQualifiers = [
        AVAssetVariantQualifier(predicate: NSPredicate(format: "peakBitRate >= 1200000"))]
}
let task = downloadSession.makeAssetDownloadTask(downloadConfiguration: configuration)
task.taskDescription = "\(releaseId)/\(sourceId)/\(position)"
task.resume()
```

   `AVAssetDownloadConfiguration` — iOS 15+ (проект целится в 16.0, `ios/project.yml`).
   Старые `makeAssetDownloadTask(asset:assetTitle:assetArtworkData:options:)` и ключи
   `AVAssetDownloadTaskMinimumRequired…` в SDK 2026 помечены deprecated — не используем.
5. **Прогресс.** `task.progress.fractionCompleted` (KVO) для полосы; точную «долю времени»
   даёт `urlSession(_:assetDownloadTask:didLoad:totalTimeRangesLoaded:timeRangeExpectedToLoad:)`
   (`sum(totalTimeRangesLoaded) / timeRangeExpectedToLoad.duration`); размер —
   `task.countOfBytesReceived` / `countOfBytesExpectedToReceive`.
6. **Завершение.** `urlSession(_:assetDownloadTask:didFinishDownloadingTo:)` даёт `location`
   (`.movpkg`) — сохранить путь в метаданные, запись → `completed`. Проигрывание:
   `AVPlayerItem(asset: AVURLAsset(url: location))`; `NativePlayerView` сейчас принимает `URL`
   ([NativePlayerView.swift:23](../ios/Anixart/Features/Player/NativePlayerView.swift)),
   понадобится инициализатор с готовым `AVAsset`/`AVPlayerItem`.
7. **Хранилище.** Метаданные — в `Application Support/Anixart/Downloads/` (JSON или SQLite;
   `OfflineCache`/`OfflineIntegration` — образец дискового слоя, но не БД загрузок). Сам
   `.movpkg` лежит там, куда его положит система по `location`; родительскую папку пометить
   `URLResourceKey.isExcludedFromBackupKey = true` (проверять после создания файлов), не
   держать в `Library/Caches` — система вычистит.
8. **Докачка/пауза.** Публичного resume у `AVAssetDownloadTask` нет: при ошибке/отмене задачу
   создают заново (перекачает ли уже скачанное — **не проверено**). Для MP4 (Sibnet) —
   `URLSession.downloadTask` с `resumeData`+`Range`, как `EpisodeFileDownloader` в Android.
   Пауза = `task.cancel()` + статус в БД; удаление = `FileManager.removeItem(at:)`.
9. **UI.** Новый экран `DownloadsView` (в iOS его нет; в [ROADMAP](../ios/ROADMAP.md) функция
   «Скачивание» помечена 🔴, п. 6 «Ближайшие шаги» — «только после разбора подписанных ссылок»):
   секции по релизам, полоса/статус/размер, пауза/отмена/удаление, «Играть», суммарный размер
   и очистка; кнопка «Скачать» — в шите выбора серии/качества, значок «скачано» — у серии.
   Настройки: только Wi-Fi, лимит места, автоудаление просмотренного; параллельность 1–2.

## Ограничения по провайдерам (таблица)

| Провайдер | Что отдаёт `episode/target` | Прямой URL (живая проверка) | Заголовки для медиа | Формат | Офлайн | Объём (720p) |
|---|---|---|---|---|---|---|
| **Libria / Liberty** | `anixart.libria.fun/…iframe.php`, `iframe:false` | API AniLibria → `cache-rfn.libria.fun/…m3u8`, `200`, media-плейлист | не нужны | HLS/TS, VOD, без DRM | **да** | ≈ 260 МБ |
| **RuTube** | обычно `rutube.ru/video/<id>/`, `iframe:false` (живых target-примеров не найдено, выборка ~70 релизов) | `bl.rutube.ru` master `200`, child `200`, сегмент `206` | не нужны | HLS/TS, VOD | **да**, ссылки живут ≈ 24 ч (master) | ≈ 223 МБ |
| **AnixPlayer / StudioMir** | `studiomir.club/…?ani=&ep=`, `iframe:true` (живых target-примеров не найдено) | `hokage-alt.studiomir.club/…m3u8` `200`, сегмент `206` | не нужны | HLS/TS, VOD | **да**, часть TR-URL мертва | ≈ 320–355 МБ |
| **Sibnet** | `video.sibnet.ru/shell.php?…`, `iframe:false` | **не проверено**: `shell.php` → `403` с нашей сети при любых UA/Referer | по Android-парсеру: UA из `config/toggles`, `Referer: shell.php` на резолве редиректа | прогрессивный MP4 | **вероятно, но непроверено** | — |
| **Kodik** | `kodikplayer.com/seria/…`, `iframe:true` | прямой GET — `500` (4 варианта заголовков); только `anixmirai.com/iframe` → HTML | — | HTML iframe, нет файла | **нет** | — |
| SovetRomantica | `sovetromantica.com/embed/…`, `iframe:true` | не разбирали (сервер помечает «не работает») | — | — | неизвестно | — |

Серверный `?download=true` в проверенных запросах отдаёт `code:0` для всех строк, включая
Kodik (но ссылки на файл всё равно нет); `download_speed_limit: 512` — у Libria/Liberty,
у остальных `0`; `is_download_disabled` в выборке везде `false`.

## План работ (этапы, оценка)
Оценка — один iOS-разработчик.

| # | Этап | Содержание | Оценка |
|---|---|---|---|
| 0 | Проверка на устройстве | `AVAssetDownloadTask` для трёх HLS-URL, локальный `.movpkg`, фон/перезапуск | 1 день |
| 1 | API и модели | `?download=true`, `download_speed_limit`, поля источника; тесты | 0.5 дня |
| 2 | URL для загрузки | резолверы: выбранный media-плейлист / master для RuTube; выбор качества | 1 день |
| 3 | DownloadManager | background-сессия, делегат, прогресс, статусы, очередь, пауза/отмена, коды 2/3 и 401/403 | 3 дня |
| 4 | Фон и восстановление | пересоздание сессии по identifier, `handleEventsForBackgroundURLSession`, статусы после запуска, force-quit | 1.5 дня |
| 5 | Хранилище и лимиты | БД/JSON, пути, `.movpkg`, `isExcludedFromBackup`, лимит места, Wi-Fi-only, очистка | 1.5 дня |
| 6 | UI | `DownloadsView`, кнопка «Скачать» и качество, прогресс на странице релиза, удаление | 2.5 дня |
| 7 | Офлайн-просмотр | `AVPlayerItem(asset:)` в `PlayerView`/`NativePlayerView`, deep link, `PlaybackProgress` | 1 день |
| 8 | Тесты и полировка | выбор URL и качества, состояние очереди, ошибки, пустые состояния | 1.5 дня |
| | **Итого** | | **≈ 13–14 дней** |

MVP (только Libria → `DownloadsView` + фон): этапы 1–5, 7 — **≈ 8–9 дней**; затем RuTube/StudioMir, Sibnet — отдельным этапом после проверки в RU-сети; Kodik в план не входит.

## Риски
* **Kodik не скачивается.** Прямой GET — `500`, прокси отдаёт HTML; нативный `KodikParser`
  обфусцирован и в живых ответах не наблюдался (`docs/PLAYERS.md` §11) — кнопку «Скачать» не показывать.
* **Подпись по IP/времени.** `episode/target` содержит `d` (похоже на `YYYYMMDDHH`), `s`, `ip`
  (наш IP `178.208.227.243`); живой `d` совпал с часом, точный TTL не измерен (ожидаемо ≤ 1 ч).
  Libria/StudioMir/RuTube это не мешает (качаем публичный CDN-плейлист), Sibnet — мешает:
  `shell.php` надо перезапрашивать после смены сети.
* **Гео.** Пробы с российского IP: Libria отдаёт `countryIso=RU`, CDN может резать другие страны;
  RuTube вне РФ — `blocking_rule`; `anilibria.top` может быть недоступен вне RU (проверить на iOS).
* **Размер и место.** 1080p StudioMir — до ~0,9 ГБ на серию; фоновая загрузка + iCloud-бэкап
  (обязательно `isExcludedFromBackup`) + нехватка места; `download_speed_limit` Libria (512) —
  возможный серверный throttling.
* **AVFoundation.** Только HLS VOD (MP4 — другим API) и без кастомных заголовков; force-quit
  убивает загрузки, публичного resume нет; ключи и колбэки `AVAssetDownloadTask` в SDK 2026 deprecated.
  Fallback — свой сегментный загрузчик, как в Android (`EpisodeFileDownloader`).
* **Ссылки живут ограниченно.** RuTube master ≈ 24 ч, сегменты ≈ 7 суток; Libria-сегмент
  редиректится с одноразовым `expires` (~17 с) — AVFoundation должен успевать следовать 302.
* **Контракт меняется.** Часть StudioMir `hls`-ссылок уже `404`; `download=true` и коды 2/3 —
  свежая функциональность 11 BETA 3+: сервер может поменять контракт (`tools/api_probe.py`).
* **Юридически/App Store.** Скачивание усиливает риск по 5.2 (`docs/RELEASE.md` §6); в App Store
  такой клиент нельзя в любом случае. Не юридическая консультация.

## Что проверить на устройстве
1. `AVAssetDownloadTask` по трём URL: Libria `cache-rfn…m3u8` (редирект сегментов), RuTube
   `bl.rutube.ru` master, StudioMir `hokage-alt…m3u8` — стартует ли и доходит до 100 %; играет ли `.movpkg`.
2. Офлайн-воспроизведение `AVPlayerItem(asset:)`, перемотка, возврат в сеть.
3. Фон/перезапуск: свернуть, заблокировать, убить и открыть — статусы и загрузки; force-quit
   (ожидаемо отменяет).
4. Смена сети Wi-Fi ↔ LTE во время загрузки; отдельно Sibnet, если доступен из страны/сети.
5. Гео: доступны ли `anilibria.top`, `cache-rfn.libria.fun`, `bl.rutube.ru`, `hokage-alt.studiomir.club`
   с iOS; не режет ли CDN по `countryIso`/UA/ATS.
6. Реальные размеры `.movpkg` для 720p/1080p, `isExcludedFromBackup`, нехватка диска.
7. `?download=true` на реальном аккаунте: `code:2/3` при ограничениях и смысл `download_speed_limit`.
8. RuTube `expire`/`sign` и мёртвые StudioMir TR-URL: переживает ли загрузка ре-резолв при 403/404.

## Источники
* Живые пробы 24.11.2026: `episode/target`, `?download=true`, `episode/{r}/{typeId}`,
  `anilibria.top/api/v1/...`, `rutube.ru/api/play/options/...`, `api.studiomir.club/api`,
  `cache-rfn.libria.fun`, `bl.rutube.ru`, `rtbcdn.ru`, `hokage-alt.studiomir.club`.
* [docs/PLAYERS.md](PLAYERS.md) — конвейер плееров, подписи `d`/`s`/`ip`, §12 «что проверить
  на устройстве»; [docs/API.md](API.md) §2.4; [docs/SDK_CROSSCHECK.md](SDK_CROSSCHECK.md)
  (строка про `?download=true`); [docs/RELEASE.md](RELEASE.md) §6.
* Android-оригинал: `analysis/unpacked/classes3.dex` — `com.swiftsoft.anixartd.utils.download.*`
  (`EpisodeLinkResolver`, `EpisodeFileDownloader`, `EpisodeDownloads`, `OfflineRestrictions`),
  `database.entity.download.EpisodeDownload`, `presentation.main.episodes.EpisodeDownloadSourcesKt`,
  `network.response.release.episode.EpisodeTargetResponse`; `analysis/strings.txt` —
  `DOWNLOAD_RESTRICTED`, `DOWNLOAD_SOURCE_RESTRICTED`, `/Download/Anixart/`.
* SDK: `anixapi-ref/src/api/release/episode.ts` — `downloadTarget`, коды 2/3.
* iOS-код: `ios/Anixart/Features/Player/{AniLibriaResolver,RutubeResolver,AnixPlayerResolver,SibnetResolver,PlaybackResolver,NativePlayerView}.swift`,
  `ios/Anixart/Core/{OfflineCache,OfflineIntegration}.swift`, [ROADMAP](../ios/ROADMAP.md).
* Apple: [AVAssetDownloadURLSession](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession),
  [AVAssetDownloadDelegate](https://developer.apple.com/documentation/avfoundation/avassetdownloaddelegate),
  [AVAssetDownloadConfiguration](https://developer.apple.com/documentation/avfoundation/avassetdownloadconfiguration),
  сэмпл «Using AVFoundation to play and persist HTTP live streams».
