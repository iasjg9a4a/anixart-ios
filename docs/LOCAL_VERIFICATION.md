# Локальная проверка без CI

GitHub Actions временно заблокирован биллингом (подробности и что делать владельцу —
в [STATUS.md](STATUS.md)), поэтому проверять изменения приходится локально. Здесь —
пять уровней проверки: от живого контракта API (секунды, без Mac) до сборки под Xcode
(только macOS). Порядок не случаен: сначала дешёвое и без Mac, потом дорогое.

Снимок: **24.11.2026**; числа по файлам и блобу — на коммите `42d433e` (с тех пор
добавлены файлы стриминговых площадок — пересчитать по команде в разделе 3). Полное
описание тестов и уровней — в [TESTING.md](TESTING.md); команды запуска и Linux-прогон
тестов — в `ios/tools/LinuxTestRunner.md`.

| Уровень | Инструмент | Нужно | Время |
|---|---|---|---|
| 1. Контракт API | `ios/tools/api_probe.py` | Python 3.8+, сеть | ~10 с |
| 2. Модели и ядро | `fetch_fixtures.py`, `swiftc`, `core_check.sh`, `ModelCheck` | `swiftc` 5.9+ | ~1–2 мин |
| 3. Typecheck приложения | `ios/tools/StubSwiftUI/check.py` | Python 3, сеть (Compiler Explorer) | ~30–90 с |
| 4. Linux-исполнение | Compiler Explorer + `LinuxTestRunner.md` | Python 3, сеть | ≈1 мин |
| 5. Сборка и UI | Xcode / `xcodebuild` | macOS + Xcode 15+ | десятки минут |

## 0. Быстрый старт

Windows (PowerShell, из корня репозитория):

```powershell
$env:PYTHONIOENCODING = 'utf-8'        # иначе api_probe.py падает на «→» в cp1251-консоли
python ios/tools/api_probe.py
python ios/tools/fetch_fixtures.py
python ios/tools/StubSwiftUI/check.py all
python ios/tools/StubSwiftUI/check.py mutate
# уровень 2 на Windows: локальный swiftc не работает (0xC0000142) — только через WSL/Docker:
wsl -- bash -lc 'cd ios && ./tools/core_check.sh'
```

macOS / Linux (bash, из корня репозитория):

```bash
python3 ios/tools/api_probe.py
python3 ios/tools/fetch_fixtures.py
cd ios && ./tools/core_check.sh && cd ..
python3 ios/tools/StubSwiftUI/check.py all
python3 ios/tools/StubSwiftUI/check.py mutate
```

На macOS полный прогон сводится к `cd ios && ./tools/check.sh`, но тесты он не запускает.

## 1. Уровень 1 — живой контракт API (`api_probe.py`)

```powershell
python ios/tools/api_probe.py                    # Windows
```

```bash
python3 ios/tools/api_probe.py                   # macOS/Linux
```

Скрипт делает **13 проверок** теми же запросами, что и приложение, и сверяет поля ответа
с тем, что ждут модели: `release/1`, `profile/1`, `filter/1`, `discover/hub`,
`POST search/releases/1`, `episode/1`, `episode/1/1`, `episode/1/1/8`,
`episode/target/1/8/1`, `collection/hub`, `collection/all/1`,
`release/comment/all/1/1` и отдельная проверка «`profile/info` без токена → HTTP 200 с
`{"code":401}`». Это 12 вызовов `check(...)` плюс ручная проверка защищённого запроса.

* Вывод: строка на проверку (`OK … байт` / `FAIL` с причиной), итог `Проблем: 0`, код 0 или 1.
* Что ловит: сервер убрал/переименовал поле или сменил тип — ровно то, что сломает
  Codable-модель.
* Чего не ловит: декодирование в Swift (уровень 2), вёрстку и поведение, авторизацию,
  пагинацию глубже первой страницы, **видео-эндпоинты** (`video/release/{id}`,
  `release/streaming/platform/{id}` в эти 13 проверок не входят).
* Бэкенд неофициальный: упавшая проверка не всегда вина клиента — повторите запуск и посмотрите тело.
* Подводный камень Windows: без `PYTHONIOENCODING=utf-8` скрипт печатает 12 строк и
  падает с `UnicodeEncodeError` на имени проверки со стрелкой «→» (cp1251-консоль).

## 2. Уровень 2 — фикстуры, модели и ядро

```powershell
python ios/tools/fetch_fixtures.py               # 1) скачать 9 реальных ответов API
wsl -- bash -lc 'cd ios && ./tools/core_check.sh'  # 2) модели + ядро + ModelCheck (Windows)
```

```bash
python3 ios/tools/fetch_fixtures.py
cd ios && ./tools/core_check.sh                  # macOS/Linux: нужен swiftc 5.9+
```

`fetch_fixtures.py` кладёт **9 фикстур** в `ios/tools/fixtures` (`release.json`,
`profile.json`, `filter.json`, `discover.json`, `search.json`, `episode_types.json`,
`episode_sources.json`, `episodes.json`, `episode_target.json`); фикстуры коммитятся
и обновляются при изменении API.

`tools/core_check.sh` без Xcode делает: `swiftc -typecheck` для `Models.swift`; typecheck
`Models.swift` + `RetryPolicy.swift` + `APIClient.swift` с заглушкой `TokenStore`
(Keychain на Linux нет); собирает `ModelCheck` и, если фикстуры на месте, гоняет его.
`ModelCheck` — **9 проверок** декодирования: `Release`, `Profile`, `Paged<Release>`
(каталог), `Discover`, `Paged<Release>` (поиск), `EpisodeTypes`, `EpisodeSources`,
`Episodes`, `EpisodeTarget` плюс инварианты (`code == 0`, непустой `displayTitle`,
валидный `URL` у видео).

Ручной прогон без скрипта (macOS/Linux): `cd ios && swiftc -o modelcheck
Anixart/Models/Models.swift tools/ModelCheck/main.swift && ./modelcheck tools/fixtures`.

* Что ловит: расхождение Codable-моделей с реальным JSON и опечатки/типы в ядре
  (`Models`, `RetryPolicy`, `APIClient`).
* Чего не ловит: SwiftUI-экраны, расширения `APIClient+*.swift`, Keychain, iOS SDK,
  доступность API iOS 16. Устаревшая фикстура может «зеленить» уже изменившийся API.
* Подводный камень: локальный `swiftc` на Windows падает (`0xC0000142`) — только WSL, Linux, Docker или CE (уровни 3–4).

## 3. Уровень 3 — стаб-стенд `StubSwiftUI` (typecheck всего приложения)

```powershell
python ios/tools/StubSwiftUI/check.py all        # = без аргумента: весь код приложения
python ios/tools/StubSwiftUI/check.py mutate     # контрольные поломки самого стенда
python ios/tools/StubSwiftUI/check.py stub       # sanity-check заглушки
```

`StubKit.swift` — минимальный фальшивый модуль SwiftUI/Combine/WebKit/AVKit/Security.
`check.py` склеивает `StubKit.swift` + все `ios/Anixart/**/*.swift`, вырезает `import`
недоступных на Linux модулей (сохраняя нумерацию строк — вместо строки пустая), отправляет
блоб в Compiler Explorer (`swift642`, `-typecheck -parse-as-library`) и печатает
`ERROR <файл>:<строка>` с номерами строк исходников.

На коммите `42d433e`: в приложении **61** `.swift`-файл, в блоб идут **58** из них плюс
`StubKit.swift` (59 частей); отчёт печатает `===== all: 649 512 байт =====` — это длина
блоба в символах (≈649 КБ; в UTF-8 на диске ≈735 КБ из-за кириллицы в комментариях).
Счёт растёт с файлами — пересчитать: `git ls-tree -r --name-only HEAD ios/Anixart | grep -c '\.swift$'`.

**Что исключено (`SKIP_STUBS` в `check.py`) и почему** — три файла:

* `Features/Player/PlayerView.swift` — полноэкранный плеер: `AVPlayer`/`AVKit`,
  `WKWebView`-обёртка `PlayerWebView`, UIKit-типы; `StubKit` не моделирует
  AVFoundation/AVKit/PiP;
* `Features/Player/NativePlayerView.swift` — нативный HLS: тот же AVKit/PiP плюс
  наблюдение за плеером и вариантами качества;
* `Features/Downloads/DownloadManager.swift` — `AVAssetDownloadURLSession` и фоновые
  загрузки HLS (`.movpkg`), вне Foundation.

Итог: три файла плеера/загрузок проверяет только уровень 5 (`xcodebuild`) — ошибку
компиляции в них до Mac/CI не видит ни один локальный уровень.

* Режимы: `all` (по умолчанию), `stub`, `mutate`. Неизвестный аргумент —
  `неизвестный аргумент: …` и код возврата 2; при ошибках — 1 (годится для скриптов).
* `check.py mutate` — самопроверка: вносит три контрольные ошибки
  (`RemoteImage(urlStrng:)`, `$model.playbackX`, `release.gradeTxt`); `SKIP` означает, что
  фрагмент не найден и мутации надо обновить, иначе стенд «зеленеет» впустую.
* Ограничения: `View` в заглушке помечен `@MainActor` (как в iOS 18 SDK), поэтому
  актор-изоляция проверяется «мягко»; не проверяются доступность API iOS 16, рантайм,
  AssetCatalog, `Info.plist`, подпись. Ошибка может быть артефактом неполной сигнатуры
  заглушки — сверяйтесь с настоящим SwiftUI. Собранные блобы кладутся в
  `ios/tools/StubSwiftUI/build/` (gitignored, не коммитить).
* Сеть обязательна: недоступность godbolt/лимит запросов = уровень пропущен (таймаут 300 с).

## 4. Уровень 4 — Compiler Explorer (Swift 6.4.2 Linux): typecheck и исполнение

Локальный `swiftc` на Windows не работает, Linux-раннера на машине нет — единственный
Swift здесь это CE (`https://godbolt.org`, компилятор `swift642` — Swift 6.4.2, Linux
x86-64). Уровень 3 использует его для typecheck; он же **исполняет** код: POST на
`api/compiler/swift642/compile` с `options.filters.execute = true` и
`compilerOptions.executorRequest = true` — CE собирает и запускает бинарник на Linux,
возвращая stdout/exit code (typecheck — `execute: false` без `executorRequest`).

Сценарий, команды и скрипт — в `ios/tools/LinuxTestRunner.md` (скрипт
`ce_linux_tests.py` лежит вне репозитория, его код вшит в документ): `python
ce_linux_tests.py` — все suite'ы, `… PlaybackTests` — один, `… --typecheck` — только
компиляция, `… --dump` — собрать блоб локально. Блоб = мини-XCTest-шим + реальные
исходники проекта + реальный тестовый файл + runner; XCTest-раннера на CE нет, поэтому
шим, но ассерты исполняются по-настоящему (`setUp`/`tearDown` вызываются).

**Результат (24.11.2026, чистое дерево `b1eb733`):** все 7 файлов `ios/AnixartTests` и все
**68 тестов** исполнены — **68 PASS, 0 FAIL**, 0 ошибок компиляции (8 блобов:
`InfrastructureTests` делится на `InfrastructureTests` + `StorageTests`); прогон повторён
дважды (цифры совпали), холодный прогон ≈57 с, повторный <1 с. Негативный контроль:
поломка `PlaybackResolver.proxyBase` роняет 2 теста, т.е. код действительно исполняется.

* Что проверяет: логику на Linux Foundation — модели и декодирование на реальных
  фикстурах, резолверы, `SourceFallbackService`, видео-модели, инфраструктуру.
* Чего не проверяет: UIKit/SwiftUI/AVKit/Security и iOS SDK, `xcodebuild test`, UI-тесты,
  Keychain/`AVPlayer`/`WKWebView` (тут заглушки), Darwin-ветку `URLSession.bytes(for:)`,
  Swift 6 strict concurrency (CE компилирует в Swift 5 mode).

## 5. Уровень 5 — Xcode/macOS: сборка, тесты, UI-тесты

```bash
cd ios
xcodegen generate
xcodebuild -project Anixart.xcodeproj -scheme Anixart \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Anixart.xcodeproj -scheme Anixart \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Anixart.xcodeproj -scheme AnixartUI \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
# или всё сразу (без тестов): ./tools/check.sh [device]
```

Единственный уровень, который проверяет: настоящий iOS SDK и доступность API iOS 16,
настоящий SwiftUI/AVKit (включая три исключённых из стенда файла), `Info.plist`/
AssetCatalog/подпись, рантайм `WKWebView`/`AVPlayer`/Keychain, 68 юнит-тестов XCTest
в 7 файлах `ios/AnixartTests` и 5 UI-тестов `ios/AnixartUITests` (схема `AnixartUI`);
скриншоты — ручной `screenshots.yml`, 12 PNG в артефакте.

Сейчас уровень 5 **недоступен**: job падает на старте из-за биллинга, Mac под рукой нет.
Поэтому новые файлы видео/фолбэка компилировались только стендом (уровень 3) и CE
(уровень 4), но не Xcode. Порядок восстановления — в [STATUS.md](STATUS.md).

## 6. Что ловит каждый уровень

Обозначения: ✅ ловит, ⚠️ частично/косвенно, — не относится, ❌ не ловит (и это дыра).

| Поломка | 1 API | 2 модели/ядро | 3 стаб-стенд | 4 CE-тесты | 5 Xcode |
|---|---|---|---|---|---|
| Сервер убрал/переименовал поле | ✅ | ✅ после обновления фикстур | — | — | — |
| Модель не декодирует реальный JSON | — | ✅ | частично (типы) | ✅ (исполнение) | — |
| Опечатка/тип в ядре (`APIClient`, `RetryPolicy`) | — | ✅ | ✅ | ⚠️ | ✅ |
| Опечатка/тип в экранах и компонентах | — | — | ✅ | — | ✅ |
| Недоступный API iOS 16 / `@available` | — | — | ❌ (заглушка не моделирует) | ❌ | ✅ |
| Нарушение актор-изоляции | — | — | ⚠️ мягко (`View` = `@MainActor`) | ❌ | ✅ |
| `PlayerView`/`NativePlayerView`/`DownloadManager` | — | — | ❌ (исключены) | ❌ | ✅ сборка |
| Логика резолверов/фолбэка/моделей видео | — | ⚠️ типы | ✅ (типы) | ✅ (исполнение) | ✅ + XCTest |
| Рантайм `WKWebView`/`AVPlayer`/Keychain | — | — | ❌ | ❌ | ❌ (только на устройстве) |
| `Info.plist`/AssetCatalog/подпись/IPA | — | — | ❌ | ❌ | ✅ сборка |
| Вёрстка, поведение, навигация | — | — | — | — | ⚠️ только UI-тесты/скриншоты |
| Видео-эндпоинты (`video/release/{id}`, площадки) | ❌ (в 13 не входят) | ❌ (нет фикстур) | ✅ типы | ✅ тесты на срезах JSON | ✅ + XCTest |

## 7. Минимальный чек-лист перед коммитом (без CI)

1. `python ios/tools/api_probe.py` — `Проблем: 0`; при изменении API ещё
   `fetch_fixtures.py` и закоммитить фикстуры.
2. `cd ios && ./tools/core_check.sh` — `OK` и `ModelCheck` 9/9 (на Windows — через WSL).
3. `python ios/tools/StubSwiftUI/check.py all` — `-> ошибок: 0`.
4. `python ios/tools/StubSwiftUI/check.py mutate` — все три мутанта пойманы (нет `SKIP`).
5. Прогнать тесты по `ios/tools/LinuxTestRunner.md`, зафиксировав suite'ы и что требует macOS.
6. Меняли `PlayerView`/`NativePlayerView`/`DownloadManager` или платформенные API — без
   уровня 5 коммит не проверен, пометить это в описании.

## 8. Честные дыры этого набора

* **Уровень 5 заблокирован** — Xcode-компиляция новых файлов (видео, фолбэк, стриминг)
  не прогонялась: это первый прогон при восстановлении Actions или на Mac.
* **CE — внешний сервис**: godbolt может ограничить частоту/быть недоступен — тогда 3–4 пропускаются (не «зелёно»).
* **Заглушка дрейфует**: новый API SwiftUI, которого нет в `StubKit.swift`, даёт ложную
  ошибку — правьте заглушку, а не исходник (`View` там `@MainActor`).
* **Контракт покрыт на 13 запросов**: видео, стриминговые площадки, видео профиля уровень
  1 не проверяет — для них остаются типы стенда и фикстурные срезы в тестах.
* **`check.sh` не заменяет тесты**: xcodegen + api_probe (предупреждение) + сборка, без XCTest.

## 9. Ссылки

[TESTING.md](TESTING.md) — полные уровни, как добавить фикстуру/проверку ·
[STATUS.md](STATUS.md) — что проверено и блокировка CI · `ios/tools/LinuxTestRunner.md` —
Linux-прогон тестов через CE · [PLAYERS.md](PLAYERS.md) — плееры и провайдеры ·
[RELEASE.md](RELEASE.md) — сборка IPA и workflow · [STYLE.md](STYLE.md) — правила кода.
