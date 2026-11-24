# Anixart iOS

Независимый SwiftUI-клиент к тому же бэкенду, что и Android-приложение Anixart 11 beta.
Подробный разбор и план — в [PORTING.md](PORTING.md); паритет и остаток работ — в
[ROADMAP.md](ROADMAP.md).

## Статус сборки

[![build](https://github.com/iasjg9a4a/anixart-ios/actions/workflows/build.yml/badge.svg)](https://github.com/iasjg9a4a/anixart-ios/actions/workflows/build.yml)

CI работает в публичном зеркале [`iasjg9a4a/anixart-ios`](https://github.com/iasjg9a4a/anixart-ios)
(на публичных репозиториях GitHub Actions бесплатны, включая macOS-раннеры).
Приватный репозиторий разработки исчерпал минуты — синхронизация срезом кода:
`python tools/mirror_to_ci.py --remote <ci-repo>` и `tools/ci_push.ps1`.

Проверено 24.11.2026 (run 45315478576):

* `core` (ubuntu-22.04, Swift 6.0) — typecheck ядра + 68 юнит-тестов;
* `ios` (macos-15) — `xcodegen generate` → `xcodebuild build` → `xcodebuild test` для симулятора;
* `ipa` — неподписанный IPA артефактом;
* `uitests` — 5 UI-тестов на симуляторе (онбординг, главная, релиз, плеер, поиск).

Итог: **68/68 юнит-тестов и 5/5 UI-тестов зелёные**, сборка под Xcode успешна.

Локально без Mac: `./tools/verify_local.ps1` (api_probe → стаб-стенд → 68 тестов через
Compiler Explorer). Подробности — `docs/LOCAL_VERIFICATION.md` и `docs/TESTING.md`.

## Требования

* macOS 13+ и Xcode 15+ (без Mac собрать нельзя: нужен iOS SDK и подпись)
* [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
* iPhone с iOS 16+

Внешних зависимостей нет — только Foundation, SwiftUI, WebKit, AVKit, Security.

## Сборка

```bash
cd ios
xcodegen generate
open Anixart.xcodeproj
```

В Xcode:

1. Выберите target **Anixart** → вкладка *Signing & Capabilities*.
2. Укажите свою Team и при необходимости поменяйте bundle id
   (`com.swiftsoft.anixart.ios`).
3. Подключите iPhone и нажмите Run.

Для бесплатного Apple ID сборка живёт 7 дней, потом нужна переподпись.
Платный Developer Program — 1 год. Подробности — [docs/RELEASE.md](../docs/RELEASE.md).

## Что умеет

17 подключённых экранов: 5 табов, 11 экранов, открывающихся из них и по deep links,
и онбординг; «Вход» — состояние экрана «Профиль». QR-вход написан, но в навигацию не
подключён. Эндпоинты, требующие токен (`?token=`), у гостя дают состояние «нужно войти».

| Экран | Данные (эндпоинты) |
|---|---|
| Главная | `discover/hub` (смотрят, обсуждают, рекомендуем, коллекции, баннеры `interesting`) + `filter/{page}`; догрузка каталога «Загрузить ещё», при ошибке сети — последний сохранённый снимок каталога |
| Поиск | пустой запрос — каталог с фильтром (сортировка «Новые/Оценка/Год/Топ», жанры, год) `filter/{page}` и чипами активного фильтра; при вводе от 2 символов — 3 сегмента: релизы `POST search/releases/{page}` (одна страница), коллекции `POST search/collections/{page}`, люди `POST search/profiles/{page}` (с догрузкой) |
| Видео релиза | `video/release/{id}` — категории (трейлеры/опенинги/эндинги/клипы), YouTube/VK/RuTube-встраивания |
| Коллекции | `collection/hub` (недели, рекомендуем, мои) + `collection/all/{page}` |
| Коллекция | `collection/{id}` (счётчики «смотрю/в планах/просмотрено/отложено/брошено») + `collection/{id}/releases/{page}` с пагинацией |
| Статьи | лента `search/feed/{page}` с пагинацией |
| Статья | `article/{id}` (блоки `payload.blocks`: header/quote/media/delimiter/paragraph) + `article/comment/all/{id}/{page}` |
| Профиль | `auth/signIn` (form-urlencoded) → `profileToken.token`, `profile/{id}`, `profile/list/all/{status}/{page}` (5 списков) |
| Чужой профиль | `profile/{id}` + счётчики списков |
| Релиз | `release/{id}`, озвучки `episode/{releaseId}`, источники `episode/{releaseId}/{typeId}`, серии `episode/{releaseId}/{typeId}/{sourceId}`, воспроизведение `episode/target/{releaseId}/{sourceId}/{position}`; связанные — из `related_releases`; действия (вход): `profile/list/add/{status}/{id}` и `profile/list/delete/{status}/{id}`, `favorite/add/{id}` и `favorite/delete/{id}`, `release/vote/add/{id}/{vote}` и `release/vote/delete/{id}` |
| Плеер | см. раздел [Плееры](#плееры); прогресс — `episode/watch/{...}` и `history/add/{...}` (нужен вход) |
| Комментарии | `release/comment/all/{releaseId}/{page}` с пагинацией; отправки/ответов/голосов нет |
| История | `history/{page}` (вход), пагинация, офлайн-снимок первой страницы |
| Избранное | `favorite/all/{page}` (вход), пагинация |
| Уведомления | `notification/all/{page}` + `notification/count` (бейдж на плитке «Профиля») + `notification/read` («прочитать все») + `notification/{type}/delete/{id}` (по одному; `notification/delete/all` есть в API, но кнопки нет) — вход |
| Друзья | `profile/friend/all/{id}/{page}`, `profile/friend/requests/in/{page}`, `profile/friend/recommendations`; действия — `profile/friend/request/send/{id}`, `.../remove/{id}`, `.../hide/{id}` (вход) |
| Настройки | локальные: аккаунт, тема (только тёмная), версия, очистка кэша изображений |
| Загрузки | офлайн-скачивание HLS (AniLibria/RuTube/AnixPlayer) через `AVAssetDownloadURLSession` |
| Вход | экран внутри «Профиля»: логин/пароль → Keychain → `?token=`; QR-экран написан, но в навигацию не подключён |
| Онбординг | 3 экрана при первом запуске, флаг `anixart.onboarding.done` |

Авторизация: `POST auth/signIn` с `application/x-www-form-urlencoded` →
`profileToken.token` → Keychain → каждый запрос получает `?token=<token>`
(заголовки сервер игнорирует — проверено). Без токена защищённые пути отвечают
`200` с `{"code":401}`.

## Плееры

> **Kodik на 24.11.2026:** API выдаёт валидную по формату ссылку, прокси `anixmirai` открывается, но сам Kodik отвечает страницей «Error code: ds» из любого нашего сетевого выхода (проверено). Это отказ на стороне Kodik; клиентская цепочка рабочая. Подробнее — `docs/PLAYERS.md`.

Anixart отдаёт в `episode/target/...` не видео, а ссылку на страницу плеера или подписанный
поток; выбирать нужно по хосту `url` и флагу `iframe`, а не по `name` источника
(разбор — [docs/PLAYERS.md](../docs/PLAYERS.md)). Реализация: `Features/Player/`
(`PlaybackResolver`, `PlayerView`, `NativePlayerView`, `PlayerWebView` + 4 резолвера).

| Провайдер | Как играется | Что нужно |
|---|---|---|
| Kodik (`iframe: true`) | WKWebView; страница загружается только через прокси Anixart `https://anixmirai.com/iframe?url=<encode>` (прямой GET Kodik отдаёт 500) | сеть до `anixmirai.com` и `kodikplayer.com`; реклама Kodik и `config/toggles` не реализованы |
| AniLibria / Libria / Liberty (`iframe: false`) | нативный резолвер: `anilibria.top/api/v1/anime/releases/{id}` → `hls_1080/720/480`, фолбэк — разбор Playerjs с подписанной `iframe.php` → AVPlayer HLS; при неудаче — WebView | доступ к `anilibria.top` и `cache*.libria.fun` (гео-параметр `countryIso` в m3u8); на устройстве не проверено |
| Sibnet (`iframe: false`) | нативный резолвер: `shell.php` с мобильным UA → regex `src:` → резолв 302 с `Referer` → MP4 → AVPlayer; при 403 повтор с Android-UA | серверный UA из `config/toggles` не подключён (захардкожен фолбэк); с нашей сети Sibnet отдаёт 403 — на устройстве не проверено |
| RuTube (`iframe: false`) | `rutube.ru/api/play/options/{id}?no_404=true&referer&pver=v2` с `Referer: https://rutube.ru/` → `video_balancer.m3u8` → AVPlayer HLS | RU-IP (иначе `blocking_rule`); на устройстве не проверено |
| AnixPlayer / StudioMir (`iframe: true`) | WebView нельзя (прокси помечает `studiomir.club` как unsupported) → `api.studiomir.club/api?ani=…&apikey=…` → `players.tsm[]` → HLS → AVPlayer | apikey захардкожен; реальных источников в выборке релизов не нашлось — на устройстве не проверено |
| YouTube | WKWebView с `<iframe youtube.com/embed/{id}>`; `videoId` вытаскивается из `watch?v=`, `youtu.be`, `/embed/`, `/shorts/` | в конвейере серий YouTube у сервера не встречался — путь для статей/трейлеров |
| Неизвестный источник | WKWebView с iframe-обёрткой и `Referer: anixart-app.com` | — |

Нативный AVPlayer (`NativePlayerView`):

* **качество** — разбор master-плейлиста HLS (`VideoQualitySelector`), меню в toolbar,
  выбор запоминается в `UserDefaults` (`anixart.video.quality`); только для нативных HLS,
  на web-плеерах и MP4 качества нет;
* **PiP** — `PiPController` на `AVPlayerLayer` нативного плеера, кнопка в toolbar;
  реализовано, на устройстве не проверено; для web-плееров PiP не делается;
* **фон** — аудиосессия `.playback` + `UIBackgroundModes: audio`; реализовано, на устройстве
  не проверено;
* **AirPlay** — `AirPlayButton` (`AVRoutePickerView`) написан, но никуда не вставлен: кнопки
  AirPlay в интерфейсе нет;
* **прогресс** — `PlaybackProgress` хранит до 50 позиций (`releaseId-sourceId-position`),
  при открытии серии делает seek, по концу — `episode/watch` и `history/add`; «Продолжить
  просмотр» (`continueWatching()`) реализовано в сервисе, но экрана нет;
* **«следующая серия»** — `NextEpisodeService` (кэш списка серий 10 минут, свежий
  `episode/target` по нажатию) готов, но к `PlayerView` не подключён;
* ошибки: таймаут 20 с на загрузку встроенного плеера, экран ошибки с кнопкой «Открыть
  в Safari», регион-лок RuTube приходит понятным текстом.

## Навигация

5 табов (`RootView` в `App/AnixartApp.swift`): **Главная**, **Поиск**, **Коллекции**,
**Статьи**, **Профиль**. Внутри табов — `NavigationStack` и `NavigationLink` (релиз из
любой карточки, профиль автора комментария, коллекция).

Модальные экраны:

* плеер — `fullScreenCover` из страницы релиза;
* комментарии релиза целиком — `sheet` кнопкой «Все»;
* история, избранное, уведомления, друзья, настройки — один `sheet` по плиткам на
  «Профиле»;
* deep link — отдельный `sheet` с кнопкой «Закрыть» (открывается после онбординга).

Deep links (`App/DeepLinkRouter.swift`): схема `anixart://` и universal links на
`anixart-app.com` / `anixart.link`, пути одинаковые:

```
anixart://release/123        anixart://search?q=naruto
anixart://profile/1          anixart://history
anixart://collection/55      anixart://favorites
anixart://settings
```

Разбор строгий: чужая схема, неизвестный путь, нечисловой `id` и пустой `q` дают `nil` —
навигация не меняется. Отладочный запуск сразу на экране (его использует CI скриншотов):
`-anixart-open-route=release/1`. Universal links требуют entitlement Associated Domains,
которого в `project.yml` пока нет — работает только кастомная схема.

## Тесты

57 XCTest-тестов в `AnixartTests/` (подключены в `project.yml` как bundle `AnixartTests`,
схема `Anixart` содержит действие `test`):

| Файл | Тестов | Что покрывают |
|---|---|---|
| `ModelsDecodingTests.swift` | 12 | декодирование фикстур `tools/fixtures/` (Release, Profile, Paged-каталог, Discover, озвучки/источники/серии, EpisodeTarget), пустое тело `{"code":0}`, составной `Episode.id`, форма ответа входа |
| `APIClientTests.swift` | 12 | `check(code)` 0/401/2/3, ответ `{"code":401}` → `.unauthorized`, пустой `Paged`, тексты `APIError`, недоступный хост → `.transport`, стенд `MockURLProtocol` |
| `InfrastructureTests.swift` | 18 | `RetryPolicy` (число попыток, экспоненциальная пауза, jitter) и `Retry.run` (успех с 3-й, исчерпание, отмена, неретраибельная ошибка), `check` с `successCodes`, deep links (валидные/мусор), офлайн-кэш каталога, `PlaybackProgress`, `ImageCache` без сети |
| `PlaybackTests.swift` | 7 | определение провайдера по имени/хосту, `videoId` YouTube, Kodik → web через прокси, сборка прокси-URL, `.m3u8` → `.hls`, тексты `PlaybackError`, `Episode` из `episode/target` |
| `ProviderResolverTests.swift` | 8 | id RuTube из четырёх шаблонов ссылок, ссылка AniLibria `id`/`ep`, её JSON и Playerjs, `ani` в ссылке StudioMir, разбор master-плейлиста качеств, запоминание выбора, HTML-парсер Sibnet |

Запуск: `xcodebuild test -project Anixart.xcodeproj -scheme Anixart -destination 'platform=iOS Simulator,name=iPhone 15'`
(в CI — первый доступный симулятор, `CODE_SIGNING_ALLOWED=NO`). Не покрыто: ViewModel и UI,
реальные сетевые запросы `APIClient` (сессия в `private init`), Keychain, поведение
WKWebView/AVPlayer на устройстве. Подробнее — [docs/TESTING.md](../docs/TESTING.md).

## CI

| Workflow | Триггер | Что делает |
|---|---|---|
| [build.yml](../.github/workflows/build.yml) | push в `main`/`master`, PR, вручную | `core` (Linux, Swift 6.0): `swiftc -typecheck` моделей и `APIClient`, `ModelCheck` на фикстурах; `ios` (macos-15): xcodegen, сборка для симулятора, юнит-тесты, `.xcresult` артефактом при падении; `ipa` (только вручную): неподписанный `Anixart-unsigned.ipa` артефактом на 14 дней |
| [release.yml](../.github/workflows/release.yml) | тег `v*` | тот же архив без подписи → `.ipa` → GitHub Release с notes |
| [screenshots.yml](../.github/workflows/screenshots.yml) | вручную | сборка под симулятор, установка, запуск с `-anixart-open-route` и съёмка 7 экранов (онбординг, релиз, поиск, главная, коллекция, настройки, история) → артефакт `ui-screenshots` на 7 дней |

Общее: новый прогон того же workflow/события/ref отменяет предыдущий; macOS-минуты на
бесплатном плане считаются ×10, поэтому job `ipa` запускается только по кнопке.
Запуск вручную: *Actions* → workflow → *Run workflow*; из CLI — `gh workflow run build.yml`.
Скачать артефакт: `gh run download <run-id> -n Anixart-unsigned-ipa -D out`.

## Установка на iPhone

Нужен Mac с Xcode (см. «Сборка») либо готовый `.ipa`:

1. **Получить `.ipa`.** Артефакт `Anixart-unsigned-ipa` из свежего прогона `build.yml`
   (*Actions* → **build** → *Run workflow* → дождаться job `ipa`) или файл из GitHub Release
   (тег `v*`). `.app`/архив из CI не подписаны — подпись делает Sideloadly.
2. **Sideloadly** (Windows/macOS) — бесплатный Apple ID: подключить iPhone по кабелю,
   перетащить `.ipa`, вписать Apple ID (понадобится 2FA и app-specific password),
   Start. Утилита подписывает приложение вашим Apple ID и устанавливает.
3. **На iPhone:** iOS 16+ — включить *Settings → Privacy & Security → Developer Mode* и
   перезагрузить; доверять разработчику — *Settings → General → VPN & Device Management →
   Apple Development → Trust*.
4. Срок: **7 дней** на бесплатном Apple ID (дальше переподписать через Sideloadly), 1 год —
   платный Developer Program. Лимит — до 3 приложений на устройстве.
   Подробнее — [docs/RELEASE.md](../docs/RELEASE.md#5-установка-на-устройство).

Чужие корпоративные сертификаты не использовать: Apple их отзывает.

## Проверка контракта API

```bash
python tools/api_probe.py
```

Скрипт повторяет запросы клиента (13 живых проверок) и сверяет поля ответов с моделями
`Anixart/Models/Models.swift`. Если Anixart поменяет API — здесь будет видно, что именно.
Контракт и коды ответов — [docs/API.md](../docs/API.md), расхождения со сторонним
SDK — [docs/SDK_CROSSCHECK.md](../docs/SDK_CROSSCHECK.md).

**Пагинация:** сервер нумерует страницы с нуля (`filter/0` — первая), а в приложении
страницы с единицы. Пересчёт сосредоточен в двух местах: `Paged.currentPage` делает `+1`
при декодировании, а `APIClient` вычитает единицу при сборке пути. В экранах везде
используется человеческая нумерация.

**Объём клиента:** 54 шаблона путей — 42 в `APIClient` и его расширениях (`Articles`,
`Feed`, `Friends`, `Notifications`, `Preferences`; шаблон `notification/{type}/delete/{id}`
раскрывается в 9 путей), 6 действий в `APIClient+Actions`, 3 заявки в друзья и 3 запроса
QR-входа (последний экран не подключён).

## Компиляция без Mac

Ядро (модели + API-клиент) собирается обычным `swiftc` на macOS и Linux:

```bash
./tools/core_check.sh
```

Проверено настоящим компилятором (Swift 6.4, Linux, Compiler Explorer): `Models.swift`,
`APIClient.swift` и `tools/ModelCheck` компилируются без ошибок и предупреждений.
Экраны на SwiftUI/WebKit/Keychain без Xcode не проверяются — для них нужен macOS, но есть
стенд заглушек: `python3 tools/StubSwiftUI/check.py` (typecheck всего кода приложения через
Compiler Explorer).

Если Mac нет вообще, iOS-сборку можно получить в CI: `.github/workflows/build.yml`
(job `ios` поднимает `macos-15`, ставит xcodegen и собирает проект).

## Известные ограничения

* **Плееры проверены только по живым запросам парсеров, не на устройстве.** Kodik идёт
  через сторонний прокси `anixmirai.com` (может отвалиться); Sibnet с нашей сети отдаёт
  403; у AnixPlayer живых источников не нашлось; RuTube требует RU-IP. Что проверять —
  [docs/PLAYERS.md](../docs/PLAYERS.md#12-что-проверить-на-устройстве).
* PiP, фоновое воспроизведение, AirPlay и качество реализованы, но на устройстве не
  проверены; кнопки AirPlay в UI нет; качество есть только у нативных HLS.
* Ссылки на видео подписаны по IP и времени, поэтому запрашиваются перед каждым показом;
  офлайн-загрузки серий без разбора этой схемы работать не будут (офлайн-кэш сейчас — только
  каталог и история, JSON в `Library/Caches/anixart-offline`).
* Вход реализован (форма + Keychain + `?token=`); по журналу ROADMAP он проверялся на
  аккаунте `<test-login>`, в этой сборке на устройстве не перепроверялся. QR-вход написан, но
  не подключён к экрану входа.
* Готовые, но не подключённые к UI слои: `APIClient+Preferences` (настройки аккаунта;
  экран настроек — локальный), `ImageCache` (экраны используют `AsyncImage`, поэтому кэш
  картинок фактически не работает; очистка в настройках чистит только `URLCache`),
  `RetryPolicy` (не подключён к `APIClient`), `NextEpisodeService` («следующая серия»),
  `PlaybackProgress.continueWatching()` (полки «Продолжить» нет), `QrLoginView`,
  `AirPlayButton`.
* Действия на странице релиза (список, избранное, оценка, поделиться) подключены, но живьём
  с токеном не проверялись: успешные ответы `profile/list/*`, `favorite/*`, `release/vote/*`
  известны только по контракту dex — записывающих запросов не делали.
* Universal links обрабатываются кодом, но entitlement Associated Domains не настроен —
  работают только `anixart://` ссылки.
* Уведомления и друзья: у тестового аккаунта 0 записей, поэтому форма живых элементов
  подтверждена только кодом/фикстурами, не живым ответом.
* Плеер сторонний (Kodik и т.п.), реклама и поведение зависят от их веб-страницы; реклама
  Kodik (`kodikAdIframeUrl`) не реализована, `config/toggles` тоже.
* App Store закрыт: правило 5.2 (см. [docs/RELEASE.md](../docs/RELEASE.md#6-app-store-почему-нельзя));
  Privacy Manifest (`PrivacyInfo.xcprivacy`) отсутствует.

## Структура

```
Anixart/
  App/          AnixartApp (RootView, TabView), Session, Theme, DeepLinkRouter/DeepLinkDestination
  Core/         APIClient + расширения (Actions, Articles, Feed, Friends,
                Notifications, Preferences), TokenStore, ImageCache, OfflineCache,
                OfflineIntegration, RetryPolicy
  Models/       Codable-модели
  Components/   RemoteImage, ReleasePoster, ShelfView, ChipView, состояния, SkeletonViews
  Features/     Home, Search (релизы/коллекции/люди + фильтры), Release, Player
                (резолверы Kodik/Sibnet/AniLibria/RuTube/AnixPlayer, NativePlayerView,
                PlaybackProgress, NextEpisodeService, VideoQuality), Collections,
                CollectionDetail, Comments, History, Favorites, Profile, Settings,
                UserProfile, Articles, Notifications, Friends, Auth (QR), Onboarding
  Resources/    Assets.xcassets (иконка), Info.plist (генерируется XcodeGen из project.yml)
AnixartTests/   XCTest: модели, APIClient, инфраструктура, плеер, резолверы (57 тестов)
tools/
  api_probe.py       проверка контракта живого API (13 проверок)
  fetch_fixtures.py  скачивание реальных ответов в tools/fixtures (9 файлов)
  ModelCheck/        проверка Codable-моделей без Xcode
  StubSwiftUI/       typecheck SwiftUI-экранов через Compiler Explorer (заглушки)
  core_check.sh      typecheck ядра без Xcode
  check.sh           xcodegen + api_probe + xcodebuild одной командой
  make_app_icon.py   генератор иконки
```

Документы: [PORTING.md](PORTING.md) — разбор APK и план порта, [ROADMAP.md](ROADMAP.md) —
паритет функций и ближайшие шаги, [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) —
устройство клиента, [docs/PLAYERS.md](../docs/PLAYERS.md) — как устроены плееры,
[docs/API.md](../docs/API.md) — справочник API, [docs/TESTING.md](../docs/TESTING.md) —
уровни проверки, [docs/RELEASE.md](../docs/RELEASE.md) — сборка и установка.
