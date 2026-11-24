# Тестирование Anixart iOS

Клиент проверяется на семи уровнях: живой контракт API, Codable-модели на реальных
ответах, typecheck приложения на стаб-заглушках, реальное исполнение юнит-тестов на
Linux, сборка и 126 XCTest под iOS SDK, 9 UI-тестов в симуляторе и 12 скриншотов.
Порядок не случаен: сначала дешёвые проверки без Mac, и только затем Xcode.

Снимок: **25.11.2026**. Тестов: **126 юнит-тестов** в 13 файлах `ios/AnixartTests`
(14 XCTest-классов: `InfrastructureTests.swift` = `InfrastructureTests` 15 +
`StorageTests` 3) и **9 UI-тестов** в `ios/AnixartUITests/SmokeUITests.swift`
(схема `AnixartUI`, job `uitests`). Linux-прогон (уровень 4) собирает 10 из 14 классов:
**86/86 PASS**, холодный прогон **≈63 с** (раздел 2.4).

> **CI идёт через публичное зеркало**: Actions в основном (приватном) репозитории
> исчерпаны по биллингу, поэтому сборка/тесты запускаются в `iasjg9a4a/anixart-ios`
> (`tools/ci_push.ps1`). Локальные уровни 1–4 остаются первой линией — раздел 5.

## 1. Уровни проверки

| # | Уровень | Инструмент | Что проверяет | Нужно | Где запускается |
|---|---|---|---|---|---|
| 1 | Контракт API | `ios/tools/api_probe.py` | **13 живых проверок**: нужные моделям поля и типы в ответах сервера | Python 3.8+, сеть | вручную, `verify_local.ps1` |
| 2 | Модели и ядро | `fetch_fixtures.py`, `core_check.sh`, `ModelCheck` | **9 фикстур → 9 проверок** декодирования; typecheck `Models`, `RetryPolicy`, `APIClient` | `swiftc` 5.9+ | вручную, CI job `core` |
| 3 | Typecheck приложения | `ios/tools/StubSwiftUI/check.py` | **67 из 72** файлов приложения на заглушке SwiftUI; блоб ≈807 КБ | Python 3, сеть (Compiler Explorer) | вручную, `verify_local.ps1` |
| 4 | Исполнение юнит-тестов | `ios/tools/linux_tests.py` | **86 тестов в 10 suite'ах** реально компилируются и исполняются на Linux | Python 3.8+, сеть (CE) | вручную, `verify_local.ps1` |
| 5 | iOS-сборка + XCTest | `xcodebuild`, схема `Anixart` | iOS SDK и API iOS 16, `Info.plist`/AssetCatalog/подпись, **126 XCTest** | macOS + Xcode 15+ | macOS, CI job `ios` (по кнопке) |
| 6 | UI-тесты | `ios/AnixartUITests`, схема `AnixartUI` | **9 смоук-сценариев** запуска, навигации и плеера | macOS + симулятор | macOS, CI job `uitests` (по кнопке) |
| 7 | Скриншоты | `.github/workflows/screenshots.yml` | сборка, установка в симулятор и **12 PNG** экранов | macOS + симулятор | вручную (`workflow_dispatch`) |

Уровни 1–4 одной командой запускает `ios/tools/verify_local.ps1` (команда — в начале раздела 2).

**Что ловит какой уровень.** ✅ ловит, ⚠️ частично/косвенно, — не относится, ❌ не ловит (это дыра).

| Поломка | 1 API | 2 модели/ядро | 3 стаб | 4 Linux-тесты | 5 Xcode | 6 UI / 7 скриншоты |
|---|---|---|---|---|---|---|
| Сервер убрал/переименовал поле | ✅ | ✅ после обновления фикстур | — | — | — | — |
| Модель не декодирует реальный JSON | — | ✅ | ⚠️ типы | ✅ `ModelsDecodingTests` | — | — |
| Опечатка/тип в ядре (`Models`, `RetryPolicy`, `APIClient`) | — | ✅ | ✅ | ⚠️ через тесты | ✅ | — |
| Опечатка/тип в экранах и компонентах | — | — | ✅ | — | ✅ | — |
| Логика резолверов, фолбэка, видео | — | ⚠️ типы | ✅ типы | ✅ исполнение | ✅ + XCTest | — |
| `PlayerView`/`NativePlayerView`/`DownloadManager` | — | — | ❌ исключены | ❌ вырезаны | ✅ только сборка | ⚠️ плеер в UI-смоуке |
| Недоступный API iOS 16, `@available`; актор-изоляция | — | — | ❌/⚠️ мягко | ❌ | ✅ | — |
| Keychain, `AVPlayer`, `WKWebView`, PiP, фон | — | — | ❌ заглушки | ❌ заглушки | ❌ только сборка | ⚠️ рантайм — на устройстве |
| `Info.plist`/AssetCatalog/подпись/IPA | — | — | ❌ | ❌ | ✅ | — |
| Вёрстка, навигация, поведение | — | — | — | — | — | ⚠️ 9 смоуков + 12 PNG глазами |
| Видео-эндпоинты и легальные площадки | ❌ не входят в 13 | ❌ нет фикстур | ✅ типы | ✅ `ReleaseVideoTests` | ✅ | — |

## 2. Как запускать

Пути — от корня репозитория; `cd ios` нужен, где указан. На Windows полезно `$env:PYTHONIOENCODING = 'utf-8'`
(иначе python-скрипты спотыкаются о «→» в cp1251-консоли). Всё локальное (уровни 1–4) разом:
`cd ios && powershell -ExecutionPolicy Bypass -File tools/verify_local.ps1` — флаги `-SkipFixtures`,
`-CeDelay 2`; скрипт гоняет api_probe → стаб-стенд → фикстуры (без сети пропуск) → linux_tests,
печатает сводку и возвращает 0, только если каждый выполненный шаг прошёл (пропуск сетевого
шага — не «зелено», exit 1). Пошаговый разбор без CI — в [LOCAL_VERIFICATION.md](LOCAL_VERIFICATION.md).

### 2.1 Контракт живого API — `api_probe.py`

```bash
python3 ios/tools/api_probe.py          # из корня (Windows: python ...)
cd ios && python3 tools/api_probe.py    # или из ios/
```

Скрипт делает те же запросы, что приложение (**13 проверок**), и сверяет поля и типы с моделями:
`release/1`, `profile/1`, `filter/1`, `discover/hub`, `POST search/releases/1`, `episode/1`,
`episode/1/1`, `episode/1/1/8`, `episode/target/1/8/1`, `collection/hub`, `collection/all/1`,
`release/comment/all/1/1` и отдельно «`profile/info` без токена → HTTP 200 с `{"code":401}`».
Вывод: `OK` + размер ответа или `FAIL` с причиной, итог `Проблем: N`.

**Не проверяет:** декодирование в Swift (это `ModelCheck`), поведение приложения, авторизацию,
пагинацию глубже первой страницы, видео-эндпоинты. Бэкенд неофициальный: `FAIL` не всегда поломка
клиента — повторите запуск и смотрите тело ответа. `ios/tools/check.sh` (macOS) гоняет
`api_probe.py`, но **не валит сборку** — печатает `ВНИМАНИЕ: API изменился`.

### 2.2 Модели и ядро — `fetch_fixtures.py`, `core_check.sh`, `ModelCheck`

```bash
python3 ios/tools/fetch_fixtures.py     # 9 реальных ответов → ios/tools/fixtures/
cd ios && ./tools/core_check.sh         # нужен swiftc 5.9+ (Windows — через WSL)
```

`fetch_fixtures.py` скачивает **9 фикстур** (`release`, `profile`, `filter`, `discover`, `search`,
`episode_types`, `episode_sources`, `episodes`, `episode_target`; коммитятся). `core_check.sh` без
Xcode делает `swiftc -typecheck` для `Models.swift`, затем для `Models.swift` + `RetryPolicy.swift`
+ `APIClient.swift` с заглушкой `TokenStore` (Keychain на Linux нет), собирает и гоняет
`ModelCheck` — **9 проверок** (`Release`, `Profile`, `Paged` каталога и поиска, `Discover`,
`EpisodeTypes`, `EpisodeSources`, `Episodes`, `EpisodeTarget`) плюс инварианты (`code == 0`,
непустой `displayTitle`, валидный `URL`). **Не проверяет:** сеть и заголовки, `APIClient` целиком,
экраны; устаревшая фикстура может «зеленить» изменившийся API, расширения `APIClient+*.swift`
в этот уровень не входят. Локальный `swiftc` на Windows падает (`0xC0000142`) — WSL/Linux/CE.

### 2.3 Typecheck приложения — `StubSwiftUI`

```bash
cd ios
python3 tools/StubSwiftUI/check.py all        # = без аргумента: весь код приложения
python3 tools/StubSwiftUI/check.py stub       # sanity-check самой заглушки
python3 tools/StubSwiftUI/check.py mutate     # контрольные поломки стенда
```

`check.py` склеивает `StubKit.swift` + все `.swift` приложения (на HEAD — **67 из 72**;
блоб `===== all: 807229 байт =====` ≈807 КБ), вырезает `import` недоступных на Linux модулей
(сохраняя нумерацию строк), отправляет в Compiler Explorer (`swift642`, `-typecheck
-parse-as-library`) и печатает `ERROR <файл>:<строка>` с номерами строк исходников и
`-> ошибок: N`; коды возврата 0/1/2. **Исключены пять файлов** (`SKIP_STUBS`): `PlayerView.swift`,
`NativePlayerView.swift`, `NativePlaybackState.swift`, `NowPlayingController.swift`,
`DownloadManager.swift` — `StubKit` не моделирует AVFoundation/AVKit/PiP, `MediaPlayer`
и фоновые HLS-загрузки, их компиляцию видит только `xcodebuild`. `mutate` вносит три контрольные
ошибки (`RemoteImage(urlStrng:)`, `$model.playbackX`, `release.gradeTxt`); `SKIP` = фрагмент не
найден, мутации надо обновить. **Ограничения:** `View` в заглушке `@MainActor` (как в iOS 18 SDK) —
актор-изоляция проверяется «мягко»; не проверяются API iOS 16, рантайм, AssetCatalog, `Info.plist`,
подпись; блобы — в `tools/StubSwiftUI/build/` (gitignored).

### 2.4 Юнит-тесты на Linux — `linux_tests.py`

```bash
cd ios
python3 tools/linux_tests.py                 # все 10 suite / 86 тестов
python3 tools/linux_tests.py --only PlaybackTests
python3 tools/linux_tests.py --typecheck     # только компиляция
python3 tools/linux_tests.py --list          # состав прогона
```

Каждый suite собирается в один Swift-файл (XCTest-шим + Linux-заглушки + реальные исходники +
тестовый файл + runner), уходит в Compiler Explorer (`swift642` — Swift 6.4.2 Linux, `execute +
executorRequest`) и **исполняется** там: `setUp`/`tearDown` и все ассерты работают по-настоящему.
Нужны Python 3.8+ и сеть до `godbolt.org`; локальный Swift/Xcode не нужен. На HEAD: **86 PASS,
0 FAIL, 0 ошибок компиляции** (9 файлов, 10 блобов; финал `TOTAL: 86/86 passed, 0 failed`);
холодный прогон **≈57–61 с**, повторный ≈13–19 с (кеш CE + пауза `--delay` между запросами).
Exit code 0 только при нуле падений; без сети уровень непройден, а не «зелён». Число 86 зашито
в `EXPECTED_TESTS` — при добавлении тестов обновить. Швы, негативный контроль (мутация `PlaybackResolver.proxyBase` роняет 2 теста) и ограничения — в
[LinuxTestRunner.md](../ios/tools/LinuxTestRunner.md): XCTest заменён шимом, Keychain/Combine —
заглушки, SwiftUI-вьюхи вырезаны, фикстуры вшиты verbatim. **Это не CI** — app target под iOS SDK стенд не собирает (раздел 5).

### 2.5 Xcode: сборка и 126 XCTest

```bash
cd ios && xcodegen generate
xcodebuild -project Anixart.xcodeproj -scheme Anixart \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Anixart.xcodeproj -scheme Anixart \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
# один класс: -only-testing:AnixartTests/ModelsDecodingTests
```

`ios/project.yml` объявляет схемы `Anixart` (build + `AnixartTests` в действии `test`) и
`AnixartUI` (`AnixartUITests`); `SWIFT_VERSION: 5.9`, iOS 16.0. В Xcode — ⌘U; `tools/check.sh` =
xcodegen + `api_probe.py` (предупреждение) + сборка, **тестов не запускает** (см. 2.4).
CI (`.github/workflows/build.yml`): `core` (`ubuntu-22.04`, Swift 6.0) — typecheck ядра и
`ModelCheck`; `ios` (`macos-15`) — сборка и `xcodebuild test`; `ipa` — неподписанный IPA;
`uitests` — UI-тесты. На push/PR только `core`, macOS-job'ы — по `workflow_dispatch` (экономия
macOS-минут), симулятор — первый доступный iPhone; при падении `ios` грузятся `.xcresult` и логи
(`ios-failure-<run>-<attempt>`), у `uitests` — `ui-tests-xcresult`; `release.yml` по тегу собирает
IPA и GitHub Release. **Не проверяет:** подпись/архив, установку на устройство, реальные
`WKWebView`/`AVPlayer`/Keychain, UI-тесты. Читать: `BUILD SUCCEEDED` / `** BUILD FAILED **`,
`Executed 126 tests, with 0 failures`; ошибки — `<файл>:<строка>: error:`.

### 2.6 Скриншоты в симуляторе — `screenshots.yml`

`.github/workflows/screenshots.yml` — ручной workflow (`workflow_dispatch`, `macos-15`, 20 минут):
собирает `Debug` под симулятор, ставит `.app` через `simctl install`, запускает приложение с
аргументами и снимает **12 PNG** в артефакт `ui-screenshots` (7 дней, грузится даже при падении):
`01-onboarding`, `02-release`, `03-search`, `04-home`, `05-collection`, `06-settings`,
`07-history`, `08-player`, `09-player-native`, `10-player-anixplayer`, `11-video-youtube`,
`12-video-vk`. Онбординг перекрывает deep link, поэтому маршрут запускается с
`-anixart.onboarding.done YES` (NSArgumentDomain) и `-anixart-open-route=release/1` /
`-anixart-open-player=1/8/1` / `-anixart-open-video=92/216`. Это **не тест**: только сборка,
запуск и отрисовка — сравнений с эталоном и проверки пикселей нет, сбой снимается глазами по артефакту.

### 2.7 UI-тесты в симуляторе — `ios/AnixartUITests`

`ios/AnixartUITests/SmokeUITests.swift` — **9 смоук-тестов** XCUITest (чёрные, без `@testable import Anixart`, сеть не подменяется):

* `testOnboardingAppears` — онбординг проходится кнопкой, появляется таб-бар с 5 вкладками;
* `testHomeLoadsShelves` — главная дорисовывает полку «Сейчас смотрят»;
* `testOpenReleaseDeepLink` — `-anixart-open-route=release/1` открывает релиз;
* `testSearchShowsResults` — `-anixart-open-route=search?q=naruto` показывает результаты;
* `testPlayerOpensForEpisode` — `-anixart-open-player=1/8/1` открывает плеер;
* `testReleaseSwitchesVoiceoverAndSeesMultipleSources` — переключение озвучки даёт больше одного источника;
* `testAllSourcesSheetShowsProviders` — шит «все источники» показывает провайдеров;
* `testPlayerHasControls` — в плеере есть ползунок и play/pause (или спиннер буферизации);
* `testPlayerCloseReturnsBack` — крестик закрывает плеер.

```bash
cd ios && xcodegen generate
xcodebuild test -project Anixart.xcodeproj -scheme AnixartUI \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
```

В CI — job `uitests` (`workflow_dispatch`, `macos-15`, 25 минут, первый iPhone, артефакт
`ui-tests-xcresult`); на push/PR не гоняются. **Ограничения:** только запуск и навигация;
содержимое экранов зависит от живого API (падение не всегда вина клиента), вёрстка и пиксели не проверяются, UI-тесты не заменяют скриншоты.

## 3. Юнит-тесты: 126 в 13 файлах

| Файл | Класс | Тестов | Что покрыто |
|---|---|---|---|
| `ModelsDecodingTests.swift` | `ModelsDecodingTests` | 12 | все 9 фикстур (`Release`, `Profile`, `Paged`, `Discover`, поиск, озвучки/источники/серии, `EpisodeTarget`), пустое тело `{"code":0}`, составной `Episode.id`, форма `AuthResponse` |
| `APIClientTests.swift` | `APIClientTests` | 12 | `APIClient.check` (0, 401, прочие коды), `ServerCode` в `episode/watch`, ответы `Release`/`Profile`, `{"code":401}` → `.unauthorized`, пустой `Paged`, `EpisodeTarget` без `episode`, тексты `APIError`, недоступный хост → `.transport`, стенд `MockURLProtocol` |
| `InfrastructureTests.swift` | `InfrastructureTests` | 15 | `RetryPolicy` (число попыток, экспоненциальная пауза, jitter, детерминизм), `Retry.run` (успех с 3-й, исчерпание, отмена, неретраибельная ошибка, `transport`), `RetryableError`, `check` с `successCodes`, deep links (валидные/мусор) |
| `InfrastructureTests.swift` | `StorageTests` | 3 | офлайн-кэш каталога (round-trip), `PlaybackProgress` (позиция сохраняется и читается), `ImageCache` без сети |
| `PlaybackTests.swift` | `PlaybackTests` | 7 | провайдер по имени/хосту, `videoId` YouTube, Kodik → web через прокси, сборка прокси-URL, `.m3u8` → `.hls`, тексты `PlaybackError`, `Episode` из `episode/target` |
| `ProviderResolverTests.swift` | `ProviderResolverTests` | 8 | RuTube из четырёх шаблонов ссылок (+ отрицательные), AniLibria `id`/`ep` и её JSON/Playerjs, `ani` StudioMir, разбор master-плейлиста качеств, запоминание выбора, HTML-парсер Sibnet (поверхностно) |
| `ReleaseVideoTests.swift` | `ReleaseVideoTests` | 6 | хостинг видео (detect, decoding объектом и строкой), декодирование среза живого ответа, `videoId` YouTube, маппинг в `PlaybackTarget`, фолбэк заголовка |
| `FallbackTests.swift` | `FallbackTests` | 5 | классификация ошибки провайдера, порядок кандидатов, разворачивание прокси в эффективный web-target, подсказки причин, HLS/YouTube-проба |
| `KodikDirectTests.swift` | `KodikDirectTests` | 14 | разбор подписанной страницы Kodik и ответа `ftor`, сборка CDN-ссылок, список качеств, отрицательные случаи |
| `QualityVariantsTests.swift` | `QualityVariantsTests` | 15 | варианты качества всех провайдеров: разбор master-плейлиста, сортировка, выбор предпочтительного, запоминание |
| `SibnetResolverTests.swift` | `SibnetResolverTests` | 9 | 6 регулярок пути видео, «видео удалено», относительные ссылки, заголовки `shell.php`, заголовки для `AVPlayer` |
| `EpisodePlaybackServiceTests.swift` | `EpisodePlaybackServiceTests` | 6 | чистые помощники полного резолва: провайдер web-цели, разворачивание прокси, нативная цель Kodik из `KodikStream` |
| `EpisodeResolutionCacheTests.swift` | `EpisodeResolutionCacheTests` | 9 | кэш резолва серий: ключ, TTL (истечение и сдвиг часов), вытеснение по лимиту, сброс для «Повторить», дедупликация подогрева |
| `EpisodeSourceDecodingTests.swift` | `EpisodeSourceDecodingTests` | 5 | терпимое декодирование `EpisodeType`/`EpisodeSource` (объект и `Int`), из-за которого раньше «был только Kodik» |
| **Итого** | **14 классов** | **126** | 13 файлов; `InfrastructureTests.swift` содержит два независимых класса |

Фикстуры ищутся от `#filePath` (`<repo>/ios/tools/fixtures`), рабочая директория не важна;
`setUp`/`tearDown` очищают `TokenStore.shared`/`UserDefaults` — тесты меняют общее состояние.
**Не покрыто:** ViewModel и UI (кроме 9 смоуков из 2.7), реальные сетевые запросы `APIClient`
(`URLSession` в `private init`, инъекции сессии нет), Keychain, вход в аккаунт, сетевые
`resolve(...)` резолверов (тестируются чистые парсеры), поведение `WKWebView`/`AVPlayer`/PiP/фона на устройстве; скриншоты — не утверждения, а картинки.

## 4. Что осталось только для macOS

1. **UI-тесты** `ios/AnixartUITests` — XCUITest + симулятор; в `linux_tests.py` их нет.
2. **Сборка app target под iOS SDK**: настоящие SwiftUI/UIKit/AVKit/WebKit, Xcode 15+, iOS 16 deployment target, доступность API, актор-изоляция под Xcode.
3. **Пять файлов, исключённых из стаб-стенда** (`PlayerView`, `NativePlayerView`, `NativePlaybackState`, `NowPlayingController`, `DownloadManager`) — до Mac/CI их не видит ни один локальный уровень.
4. **Реальные Keychain, `AVPlayer`/`AVPlayerItem`, `WKWebView`, PiP, фоновые загрузки** — на Linux и в стенде только заглушки/вырезаны.
5. **Darwin-ветка** `URLSession.bytes(for:)` в preflight-проверке плеера (на Linux компилируется ветка `#if canImport(FoundationNetworking)` через `data(for:)`).
6. **Подпись, архив, IPA, GitHub Release** — job `ipa`/`release.yml`; **скриншоты** — `screenshots.yml` (симулятор, `simctl`, 12 PNG).
7. **Swift 6 strict concurrency**, если проект переедет на language mode 6 (CE компилирует в Swift 5).

## 5. Когда CI недоступен

**Факт:** в основном (приватном) репозитории GitHub Actions заблокирован биллингом — исчерпан
бесплатный лимит минут (macOS-раннеры на приватном репозитории тарифицируются ×10), GitHub
отвечает «The job was not started because recent account payments have failed or your spending
limit needs to be increased». Обход (с 24.11.2026): срез кода зеркалится в **публичный**
CI-репозиторий `iasjg9a4a/anixart-ios`, где Actions бесплатны, включая macOS, —
`tools/ci_push.ps1` (или `tools/mirror_to_ci.py` + `gh workflow run build.yml`); подробности
в [STATUS.md](STATUS.md). Сборка/IPA/UI-тесты/скриншоты запускаются по `workflow_dispatch`,
на push крутится только `core`. Последний зелёный прогон — run 45477026098
(`BUILD SUCCEEDED`, 126/126 XCTest, 9/9 UI-тестов, IPA).

**Чем проверять сейчас:** полный гайд по локальным уровням и честные дыры —
[LOCAL_VERIFICATION.md](LOCAL_VERIFICATION.md); 86 юнит-тестов без macOS и Xcode —
[`ios/tools/linux_tests.py`](../ios/tools/linux_tests.py) (устройство стенда —
[LinuxTestRunner.md](../ios/tools/LinuxTestRunner.md)); всё локальное одной командой —
`ios/tools/verify_local.ps1`; контракт — `api_probe.py` (13), модели — `core_check.sh` +
`ModelCheck` (9), typecheck — `StubSwiftUI/check.py`. Базовый результат на HEAD: `api_probe` 13/13,
`ModelCheck` 9/9, `StubSwiftUI` 0 ошибок, `linux_tests` 86/86, `verify_local.ps1` — 4/4 PASS,
exit 0. Эти цифры и есть «зелёный локальный прогон» — не больше.

> **Без Xcode это замена, а не CI.** Уровни 1–4 не собирают приложение под iOS SDK: настоящие
> SwiftUI/UIKit/AVKit/WebKit, доступность API iOS 16, три исключённых файла плеера/загрузок,
> Keychain, `AVPlayer`/`WKWebView`/PiP и актор-изоляция проверяются только `xcodebuild`; 9 UI-тестов
> и 12 скриншотов требуют симулятора. **86/86 на Linux — это не «iOS-сборка зелёная»**: другой
> Foundation, платформенные модули заменены заглушками. Не встраивайте CE-прогон в обязательные проверки вместо CI.

**Когда Actions разблокируют** — сначала вернуть job `ios` на текущем дереве (Xcode-компиляция
новых файлов видео/фолбэка ещё не прогонялась), затем `uitests` и `screenshots`; локальный прогон оставить pre-check'ом для машины без macOS.

## 6. Чек-лист перед релизом

Без macOS (обязательный минимум; одна команда — `verify_local.ps1`):

- [ ] `python3 ios/tools/api_probe.py` — все `OK`, `Проблем: 0`; при изменении API ещё `fetch_fixtures.py`, фикстуры обновлены и закоммичены.
- [ ] `python3 ios/tools/StubSwiftUI/check.py all` — `-> ошибок: 0`; `check.py mutate` — все три мутанта пойманы (нет `SKIP`).
- [ ] `cd ios && python3 tools/linux_tests.py` — `TOTAL: 86/86 passed, 0 failed`, exit code 0 (через WSL/Linux — ещё и `./tools/core_check.sh`, 9/9).
- [ ] Если менялись `PlayerView`/`NativePlayerView`/`DownloadManager` или платформенные API — без macOS/CI коммит **не проверен**, это надо явно написать в описании.

С macOS или CI (перед merge/релизом):

- [ ] `xcodegen generate` и `xcodebuild build` — `BUILD SUCCEEDED`.
- [ ] `xcodebuild test -scheme Anixart` — `Executed 126 tests, with 0 failures`.
- [ ] `xcodebuild test -scheme AnixartUI` — 9 UI-тестов зелёные (или job `uitests`).
- [ ] job `ios` (и `ipa` перед релизом) — зелёные; `uitests`/`screenshots` — по кнопке.
- [ ] `screenshots.yml` — 12 PNG в артефакте `ui-screenshots`, просмотрены глазами.
- [ ] `release.yml` по тегу — IPA в GitHub Release и запись в [CHANGELOG.md](CHANGELOG.md).

Не коммитить и не путать с тестами: `ios/Anixart.xcodeproj/`, `ios/build/`,
`ios/tools/StubSwiftUI/build/`, `__pycache__/` — в `.gitignore`; фикстуры `ios/tools/fixtures/*.json`
и `PrivacyInfo.xcprivacy`, наоборот, коммитятся. `check.sh` не заменяет тесты (нет XCTest/UI-тестов),
а `linux_tests.py` не заменяет `xcodebuild`: это разные платформы и разные проверки.

## 7. Как добавить проверку

**Тест.** `func test...()` в существующий класс или новый файл `ios/AnixartTests/<Тема>Tests.swift`
(XcodeGen подхватит через `sources: AnixartTests`). Для Linux-прогона новый файл надо добавить в
`SUITES` в `ios/tools/linux_tests.py` (`test_file` + `sources`), а `EXPECTED_TESTS` увеличить —
методы внутри файла собираются регуляркой автоматически. Модели проверяются на фикстурах, логика — на инлайн-JSON.

**Фикстура.** Запись в `ENDPOINTS` (`ios/tools/fetch_fixtures.py`) →
`python3 ios/tools/fetch_fixtures.py` → `expect("...")` в `ios/tools/ModelCheck/main.swift` → при
желании декодирование в XCTest → прогнать `core_check.sh` (число проверок должно вырасти) и `linux_tests.py`.

**Проверка контракта.** Вызов `check(name, path, required, method=..., body=...)` в `main()` файла
`ios/tools/api_probe.py`; `required` — «путь до поля → ожидаемый тип» (путь через точку, `[]` —
первый элемент списка, `None` — «поле есть, тип любой»). Имена полей — из реального JSON
(`snake_case`), а не из свойств модели; пути — из `analysis/endpoints.txt`. Прогнать дважды: контракт неофициального бэкенда «моргает».

## 8. Ссылки

[LOCAL_VERIFICATION.md](LOCAL_VERIFICATION.md) — проверка без CI, пошагово и с дырами ·
[STATUS.md](STATUS.md) — биллинг Actions и что проверено · [LinuxTestRunner.md](../ios/tools/LinuxTestRunner.md) —
Linux-прогон 86 тестов через Compiler Explorer · [PLAYERS.md](PLAYERS.md) — плееры и провайдеры ·
[RELEASE.md](RELEASE.md) — сборка IPA, подпись, workflow · [STYLE.md](STYLE.md) — правила кода · [ARCHITECTURE.md](ARCHITECTURE.md) — обзор проекта.
