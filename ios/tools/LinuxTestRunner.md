# LinuxTestRunner — юнит-тесты Anixart на Compiler Explorer (без macOS и без GitHub Actions)

> **Это замена, а не CI.** Стенд исполняет чистую логику под Linux Foundation на публичном
> Compiler Explorer. Он не собирает iOS-приложение, не подменяет `xcodebuild test` и не даёт
> «зелёный CI». Когда биллинг GitHub Actions разблокируют — вернуть job `xcodebuild test`
> на `macos-14`; этот прогон оставить как pre-check для машины без macOS.

Дата прогона: **24.11.2026**, база: commit `b1eb733` (чистое рабочее дерево; тесты в
`ios/AnixartTests` не изменялись). Компилятор: CE `swift642` — Swift 6.4.2, Linux x86-64
(на этой Windows-машине локальный `swiftc` не запускается, поэтому весь стенд — через
`POST https://godbolt.org/api/compiler/swift642/compile`).

## 1. Итог: 68/68 тестов исполнено и пройдено

Все 7 файлов `ios/AnixartTests/*.swift`, все 68 методов `test*()` —
**68 PASS, 0 FAIL, 0 compile errors, 0 пропущено**. `InfrastructureTests.swift`
содержит два класса (`InfrastructureTests` + `StorageTests`), поэтому блобов 8.
Полный прогон выполнен дважды (с интервалом ~6 минут, второй раз — с нуля на чистом
дереве `b1eb733`): оба раза 68/68, цифры совпали.

| Suite (класс) | Файл тестов | Источники проекта в блобе | Тестов | PASS | FAIL | Skip |
|---|---|---|---|---|---|---|
| `ReleaseVideoTests` | `AnixartTests/ReleaseVideoTests.swift` | Features/Player/PlaybackTarget.swift, Features/Release/ReleaseVideoModels.swift | 6 | **6** | 0 | 0 |
| `ModelsDecodingTests` | `AnixartTests/ModelsDecodingTests.swift` | Models/Models.swift + tools/fixtures/*.json (вшиты verbatim) | 12 | **12** | 0 | 0 |
| `PlaybackTests` | `AnixartTests/PlaybackTests.swift` | Models/Models.swift, Features/Player/PlaybackTarget.swift, PlaybackResolver.swift | 7 | **7** | 0 | 0 |
| `ProviderResolverTests` | `AnixartTests/ProviderResolverTests.swift` | PlaybackTarget.swift, VideoQuality.swift*, RutubeResolver.swift, AniLibriaResolver.swift, AnixPlayerResolver.swift, SibnetResolver.swift | 8 | **8** | 0 | 0 |
| `FallbackTests` | `AnixartTests/FallbackTests.swift` | Models/Models.swift, Core/APIClient.swift, RetryPolicy.swift, PlaybackTarget.swift, PlaybackCandidate.swift, PlaybackResolver.swift, SourceFallbackService.swift | 5 | **5** | 0 | 0 |
| `InfrastructureTests` | `AnixartTests/InfrastructureTests.swift (класс InfrastructureTests)` | Models/Models.swift, Core/APIClient.swift, RetryPolicy.swift, App/DeepLinkRouter.swift | 15 | **15** | 0 | 0 |
| `StorageTests` | `AnixartTests/InfrastructureTests.swift (класс StorageTests)` | Models/Models.swift, Core/APIClient.swift, RetryPolicy.swift, OfflineCache.swift, OfflineIntegration.swift*, ImageCache.swift*, Features/Player/PlaybackProgress.swift | 3 | **3** | 0 | 0 |
| `APIClientTests` | `AnixartTests/APIClientTests.swift` | Models/Models.swift, Core/APIClient.swift, RetryPolicy.swift | 12 | **12** | 0 | 0 |
| **Итого** | 7 файлов, 8 блобов | — | **68** | **68** | **0** | **0** |

Найденных багов нет: все проверки прошли, падений/ошибок компиляции не было.
Это значит «в текущих тестах расхождений нет», а не «приложение без багов».

**Стенд проверен негативным контролем** (Приложение B): в реальный
`PlaybackResolver.proxyBase` вносится поломка (`anixmirai.com` → `mutated.invalid`),
после чего `testKodikURLIsWeb` и `testProxiedURLAcceptsQuery` обязаны упасть — падают
(2 failed assertions, остальные 5 PASS). То есть тесты действительно исполняются, а не
просто печатается «PASS».

## 2. Как запустить

Нужны только **Python 3.8+** и сеть до `godbolt.org`; локальный Swift/Xcode не нужен.
Скрипт теперь часть репозитория — [`ios/tools/linux_tests.py`](linux_tests.py) (Приложение A
свёрнуто в ссылку), копировать его в `%TEMP%` больше не нужно. Из каталога `ios/`:

```powershell
cd ios
python tools/linux_tests.py        # одна команда: все 8 блобов / 68 тестов
```

Из любого другого каталога — `python ios/tools/linux_tests.py`: путь к репозиторию скрипт
берёт от своего расположения, а не хардкодом.

Полезные флаги (полный список — `python tools/linux_tests.py --help`):

```powershell
python tools/linux_tests.py --only PlaybackTests             # один класс
python tools/linux_tests.py --only StorageTests,APIClientTests
python tools/linux_tests.py --typecheck                      # только компиляция, без запуска
python tools/linux_tests.py --json report.json               # + per-test отчёт в JSON
python tools/linux_tests.py --dump                           # собрать блоб локально (отладка)
python tools/linux_tests.py --list                           # что входит в прогон
```

По умолчанию скрипт не пишет ничего в репозиторий: отчёт появляется только при
`--json <файл>`, блобы — только при `--dump`. Запросы к публичному CE идут последовательно
(`--delay`, по умолчанию 1 с) с повторами на 429/5xx (`--retries`, `--timeout`).

Все четыре доступных без macOS уровня разом запускает `ios/tools/verify_local.ps1`
(api_probe → typecheck по заглушке → фикстуры → тесты; без сети шаги помечаются
пропущенными, а не «зелёными»):

```powershell
cd ios
powershell -ExecutionPolicy Bypass -File tools/verify_local.ps1
```

Проверено на этом HEAD (24.11.2026, Python 3.10.11, Windows): `python tools/linux_tests.py`
— **68/68 PASS, 0 FAIL, 0 ошибок компиляции**, exit code 0, ≈61 с.

Что смотреть в выводе: строки `PASS`/`FAIL` по каждому методу, `CE-SUMMARY suite=... total=...`,
финальные `TOTAL: 68/68 passed, 0 failed` и `CE-RESULT: ALL PASSED`. Exit code 0 только если
во всех блобах 0 упавших тестов и 0 ошибок компиляции. `--json` пишет полный per-test
отчёт (`suites[].per_test`, `totals`, `ok`).
Режим `--typecheck` не запускает код: печатает `compile_errors` и возвращает 1 при первой
же ошибке компиляции. На 24.11.2026: **0 ошибок компиляции во всех 8 блобах**.

Время: первый (холодный) прогон блоба — **5–10 с** (компиляция на CE), все 8 блобов —
**57–61 с** (замерено). Повторный запуск мгновенный (<1 с на блоб): CE кэширует результат по
хешу исходника, поэтому и цифры воспроизводимы один в один. Крупнейший блоб — 381 КБ
(модели + реальные фикстуры); CE принимает такой объём (проверены блобы до 1 МБ).

### Что именно уходит на Compiler Explorer

```json
POST https://godbolt.org/api/compiler/swift642/compile
{
  "source": "<единый Swift-файл: шим + исходники + тесты + runner>",
  "options": {
    "userArguments": "",
    "filters": { "execute": true },
    "compilerOptions": { "executorRequest": true }
  },
  "lang": "swift"
}
```

Исполнение реальное: CE собирает файл `swiftc`, запускает его и отдаёт `stdout`/`stderr`
(в ответе `code`, `didExecute`, `buildResult.code`). Для `--typecheck` отправляется
`filters.execute=false` **без** `executorRequest` — тогда CE только компилирует.
Диагностика компилятора (`<source>:line:col: error:`) переводится обратно в
`файл проекта:строка` по карте диапазонов блоба.

## 3. Состав блоба и швы (что подменено, а что настоящее)

В каждом блобе, по порядку: **мини-XCTest-шим** → (опционально) вшитые фикстуры →
**реальные исходники проекта** → **реальный тестовый файл** → сгенерированный runner.

Настоящее (без изменений логики):

* все тела исходников проекта и все `XCTAssert*`/`throws`/`async`/`@MainActor` в тестах —
  как в репозитории;
* фикстуры `ios/tools/fixtures/*.json` вшиты **verbatim** (375 КБ, реальные ответы API);
* `async`-тесты, `await`, актёры (`OfflineCache`, `ImageCache`), `UserDefaults`, `URLSession`,
  `URLProtocol`/`MockURLProtocol` — исполняются по-настоящему под Linux Foundation.

Подмены/вырезки (только там, где Linux не умеет):

| Darwin-зависимость | Что сделано на Linux |
|---|---|
| `XCTest` | мини-шим: `XCTFail`, `XCTAssertEqual` (+`accuracy`, опционалы), `NotEqual`, `Nil/NotNil`, `True/False`, `NoThrow/ThrowsError`, `Greater/Less(OrEqual)`, `XCTUnwrap`; `setUp()/tearDown()` вызываются перед/после каждого теста; падение любого ассерта помечает тест FAIL |
| `Security`/Keychain (`TokenStore`) | класс-заглушка с тем же интерфейсом (`shared`, `token`, `save`, `clear`), хранение в памяти. Реальный Keychain здесь не проверяется |
| `Combine` (`ObservableObject`, `@Published`) | пустой протокол + property wrapper только для хранения значения (без издателя). Поведение Combine не проверяется |
| `NSUserActivity` | заглушка с `webpageURL` (deep-link роутер) |
| `SwiftUI`/`UIKit`/`AVKit`/`WebKit`/`AVFoundation` | импорты вырезаются; **вырезаны только SwiftUI-вьюхи**, не логика: `VideoQualityMenu` (`VideoQuality.swift`, после `// MARK: - Меню`), `OfflineDataBadge` (`OfflineIntegration.swift`, после `// MARK: - Индикатор`), `CachedAsyncImage` (`ImageCache.swift`, после `/// Замена AsyncImage`). `actor ImageCache`, `VideoQualitySelector`, `OfflineIntegration` остаются настоящими |
| Файловая система фикстур | в `ModelsDecodingTests` подменена ровно одна строка хелпера: чтение `Data(contentsOf: fixturesDirectory/appendingPathComponent(name))` → `Data(EmbeddedFixtures.text(name).utf8)` (данные те же, байт в байт) |
| Разделение одного файла тестов | `InfrastructureTests.swift` режется на два блоба по маркеру `// MARK: - Дисковый кэш и прогресс просмотра` (классы независимы) |

Важное следствие: `SourceFallbackService.checkWebPage` в репозитории уже имеет
`#if canImport(FoundationNetworking)` (Linux-ветка через `data(for:)`); на Linux компилируется
именно она, Darwin-ветка с потоковым `bytes(for:)` и обрывом на 64 КБ здесь **не проверяется**.
Языковой режим CE по умолчанию — Swift 5 (strict concurrency Swift 6 не проверяется).

## 4. Что осталось только для macOS (и не покрыто этим прогоном)

1. **UI-тесты** `ios/AnixartUITests/SmokeUITests.swift` — XCTest UI + симулятор; на CE их нет.
2. **Сборка app target под iOS SDK**: настоящие SwiftUI/UIKit/AVKit/WebKit, Xcode 15+
   toolchain, iOS 16 deployment target, доступность API, actor-isolation под Xcode,
   `xcodegen generate` + подпись/установка.
3. **Реальные Keychain** (Security), `AVPlayer`/`AVPlayerItem`, `WKWebView`, PiP,
   фоновые загрузки `DownloadManager` — на Linux только заглушки/вырезано.
4. **Darwin-ветка** `URLSession.bytes(for:)` в preflight-проверке плеера.
5. **Живой контракт API** — это не unit-тесты, а `tools/api_probe.py` (отдельный стенд).
6. **Swift 6 strict concurrency**, если проект переедет на language mode 6.
7. `xcodebuild test` как таковой (CI после разблокировки Actions).

## 5. Предупреждение

* Compiler Explorer — **публичный** сервис без SLA: может быть недоступен, ограничивать
  частоту, менять API. Исходники, отправленные в публичный CE, могут быть видны/закэшированы
  на его стороне — не отправляйте туда секреты (в этом стенде их нет: только код репозитория
  и реальные ответы API, которые и так публичные).
* Результат кэшируется по содержимому блоба: повтор того же блоба мгновенный, но после правки
  любого включённого файла кеш промахивается и блоб компилируется заново.
* 68/68 на Linux — это **не** «iOS-сборка зелёная»: другой Foundation, нет UIKit/SwiftUI,
  Keychain и AVFoundation не задействованы. Для релиза нужен macOS.
* Не встраивать этот стенд в обязательные проверки вместо CI: он вспомогательный, для
  Windows-машины и для периода, пока Actions недоступен.

## Приложение A. Скрипт `linux_tests.py` — свёрнуто в ссылку

Раньше полный листинг стенда был вшит в этот документ (его сохраняли как
`%TEMP%\anixart-ce\ce_linux_tests.py`). Теперь скрипт лежит в репозитории:
**[`ios/tools/linux_tests.py`](linux_tests.py)** — копировать вручную не нужно, см. раздел 2.
Там же все флаги (`--only`, `--typecheck`, `--json`, `--dump`, `--list`, `--delay/--timeout/
--retries`) и docstring с тем же описанием, что было в листинге.

В документе остались разделы 1–5 (итог прогона, состав блоба и швы, что не покрыто) и
Приложения B–C. Старый листинг `ce_linux_tests.py` восстанавливается из истории git —
коммит `872072e` («LinuxTestRunner: 68/68 unit tests pass via CE»).

Приложение B ниже импортирует модуль по имени `ce_linux_tests.py`; с репозиторным файлом
достаточно заменить путь на `linux_tests.py` — точка входа та же (`build_suite()`, `post()`).

## Приложение B. Негативный контроль `negctl.py`

Проверяет, что стенд реально ловит поломки: гоняет `PlaybackTests` дважды — на настоящих
исходниках (ожидается 7/7) и с мутацией в `PlaybackResolver.proxyBase` (ожидается FAIL
у `testKodikURLIsWeb` + `testProxiedURLAcceptsQuery`). Тестовый файл не меняется.

```python
#!/usr/bin/env python3
"""Negative control: prove the CE stand really executes tests and reports failures.

Runs PlaybackTests twice: once as-is (must be all-pass) and once with a logic
mutation injected into a *project source* (PlaybackResolver.proxyBase), where
the real test must fail. The test file itself is untouched.
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("ce_linux_tests", HERE / "ce_linux_tests.py")
ce = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ce)


def run(blob, spans, label):
    result = ce.post(blob)
    stdout = [i.get("text", "") for i in result.get("stdout", [])]
    summary = [l.strip() for l in stdout if "CE-SUMMARY" in l or "CE-RESULT" in l or l.startswith("FAIL ")]
    print(f"--- {label}: code={result.get('code')} didExecute={result.get('didExecute')}")
    for line in summary:
        print("   ", line.strip())
    return result


def main():
    blob, spans, klass, methods = ce.build_suite("PlaybackTests")
    base = run(blob, spans, "baseline (real sources)")
    if "CE-RESULT: ALL PASSED" not in "\n".join(i.get("text", "") for i in base.get("stdout", [])):
        print("UNEXPECTED: baseline is not all-pass, negative control meaningless")
        return 1

    mutated = blob.replace(
        'static let proxyBase = "https://anixmirai.com/iframe?url="',
        'static let proxyBase = "https://mutated.invalid/iframe?url="',
        1,
    )
    if mutated == blob:
        print("mutation not applied (anchor not found)")
        return 1
    bad = run(mutated, spans, "mutation in PlaybackResolver.proxyBase")
    out = "\n".join(i.get("text", "") for i in bad.get("stdout", []))
    if "FAIL testKodikURLIsWeb" in out or "CE-RESULT: FAILURES" in out:
        print("NEGATIVE-CONTROL OK: injected logic bug is caught as test failure")
        return 0
    print("NEGATIVE-CONTROL BROKEN: mutation was not caught")
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

## Приложение C. Пример вывода

```
===== PlaybackTests: compile+execute, blob 55377 bytes, tests 7 =====
  http-ok code=0 build=0 didExecute=True timedOut=False compile_errors=0
  PASS testProviderDetection
  PASS testYouTubeVideoIdExtraction
  PASS testKodikURLIsWeb
  PASS testProxiedURLAcceptsQuery
  PASS testM3U8IsHLS
  PASS testPlaybackErrorDescriptions
  PASS testEpisodeFromTarget
  CE-SUMMARY suite=PlaybackTests total=7 passed=7 failed=0
...
  CE-RESULT: ALL PASSED

===== FINAL =====
PlaybackTests: 7/7 passed, 0 failed, compile_errors=0
TOTAL: 68/68 passed, 0 failed
report saved to report.json
```
