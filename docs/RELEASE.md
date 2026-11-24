# Сборка и публикация Anixart iOS

Практическая инструкция: как собрать iOS-клиент Anixart из [`ios/`](../ios/README.md),
проверить в CI и поставить на устройство. [Раздел 6](#6-app-store-почему-нельзя)
объясняет, почему публикация в App Store невозможна и что легально делать вместо неё.

Снимок: **24.11.2026**, коммит `7b4703e`. Исходные данные:
[`ios/project.yml`](../ios/project.yml), [`ios/README.md`](../ios/README.md),
[`ios/ROADMAP.md`](../ios/ROADMAP.md), [`ios/tools/`](../ios/tools/check.sh),
[`.github/workflows/`](../.github/workflows/build.yml). Теги `v*` в репозитории пока
не создавались — `release.yml` ещё не запускался.

## 1. Требования

| Компонент | Минимум | Комментарий |
|---|---|---|
| macOS | 13+ (Xcode 15), 14.5+ (Xcode 16) | iOS SDK есть только на macOS; на Windows/Linux проект не собрать |
| Xcode | 15.0 или 16.x | `projectFormat: xcode15_0`, `SWIFT_VERSION: 5.9`, iOS 16.0 |
| XcodeGen | свежий из Homebrew | `brew install xcodegen`; проект генерируется из `project.yml` |
| Apple ID | бесплатный или Developer Program | без Apple ID нельзя подписать и установить на устройство |
| iPhone/iPad | iOS 16+ | `IPHONEOS_DEPLOYMENT_TARGET: "16.0"`, family 1,2 |

Внешних зависимостей нет: только Foundation, SwiftUI, WebKit, AVKit, Security, UIKit.
Python 3 нужен только для `tools/api_probe.py`, не для сборки.

Ключи `Info.plist` не лежат файлом в репозитории: он генерируется XcodeGen из блока
`info.properties` в `ios/project.yml` — там `UIBackgroundModes: [audio]` (фоновое аудио
плеера), `CFBundleURLTypes` со схемой `anixart` (deep links), `NSAllowsArbitraryLoads: true`,
`UIUserInterfaceStyle: Dark`, портрет + два ландшафта, `NSCameraUsageDescription`/
`NSPhotoLibraryUsageDescription` (смена аватара не реализована). Entitlements-файла нет,
`PrivacyInfo.xcprivacy` есть, но сборкой не проверен — см. [раздел 8](#8-privacy-manifest-privacyinfoxcprivacy).

## 2. Сборка локально

```bash
brew install xcodegen          # один раз
cd ios
xcodegen generate              # создаёт Anixart.xcodeproj из project.yml
open Anixart.xcodeproj
```

В Xcode: target **Anixart** → *Signing & Capabilities* → выбрать свою **Team**
(при необходимости сменить bundle id `com.swiftsoft.anixart.ios`, он должен быть
уникален в команде) → выбрать симулятор или iPhone → **Run** (⌘R).

Одной командой без GUI — `ios/tools/check.sh` (без аргументов — симулятор без подписи,
`device` — устройство). Скрипт проверяет `xcodegen`, гоняет 13 живых проверок контракта
API (`python3 tools/api_probe.py`, ошибки — предупреждением) и собирает проект; **тесты
не запускает**:

```bash
cd ios
./tools/check.sh            # xcodegen + api_probe + сборка под симулятор
./tools/check.sh device     # сборка под устройство
```

`ios/Anixart.xcodeproj/` в `.gitignore` — после клона обязателен `xcodegen generate`;
правки в Xcode UI (Team, bundle id, файлы) **теряются при следующем `xcodegen generate`**,
постоянные настройки — только в `project.yml`. Версия приложения — `MARKETING_VERSION: "1.0"`,
сборка — `CURRENT_PROJECT_VERSION: "1"` (там же). Ядро без Xcode: `./tools/core_check.sh`,
тесты — `xcodebuild test` (см. [docs/TESTING.md](TESTING.md)).

## 3. CI: GitHub Actions

В репозитории **три workflow**; macOS-раннер везде `macos-15` (arm64), Linux-раннер —
`ubuntu-22.04`. Concurrency: новый прогон того же workflow/события/ref отменяет предыдущий.

| Workflow | Триггер | Job'ы (раннер) | Артефакты |
|---|---|---|---|
| [`build.yml`](../.github/workflows/build.yml) | push в `main`/`master`, PR, вручную | `core` (`ubuntu-22.04`), `ios` (`macos-15`), `ipa` (`macos-15`, только вручную), `uitests` (`macos-15`, только вручную) | `Anixart-unsigned-ipa` (`.ipa`, 14 дней) в `ipa`; `ios-failure-<run>-<attempt>` (`.xcresult` + логи, 7 дней) при падении `ios`; `ui-tests-xcresult` (7 дней) у `uitests` |
| [`release.yml`](../.github/workflows/release.yml) | push тега `v*` | `release` (`macos-15`) | `Anixart-unsigned-ipa` (14 дней) + файл в GitHub Release |
| [`screenshots.yml`](../.github/workflows/screenshots.yml) | вручную (`workflow_dispatch`) | `screenshots` (`macos-15`, таймаут 20 мин) | `ui-screenshots` (7 PNG, 7 дней; грузится даже при падении) |

**`build.yml`.**

* `core` (`ubuntu-22.04`): `swift-actions/setup-swift@v2` со Swift **6.0**, `swiftc
  -typecheck` для `ios/Anixart/Models/Models.swift` и (с заглушкой `TokenStore`)
  `ios/Anixart/Core/APIClient.swift`, затем `ModelCheck` на 9 фикстурах.
* `ios` (`macos-15`): кэш Homebrew → `brew install xcodegen` → `xcodegen generate` →
  `xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
  build` (DerivedData кэшируется с версией Xcode в ключе) → `xcodebuild test` на **первом
  доступном** симуляторе (`xcrun simctl list devices available -j`, не фиксированный
  iPhone 15) с `.xcresult`.
* `ipa` (`macos-15`, только `workflow_dispatch`): архив `Release` под `iphoneos` без
  подписи (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`) →
  `Payload/Anixart.app` → `zip` → артефакт **`Anixart-unsigned-ipa`** (14 дней) с файлом
  `Anixart-unsigned.ipa`.
* `uitests` (`macos-15`, только `workflow_dispatch`, таймаут 25 минут): `xcodegen generate`
  → `xcodebuild test -scheme AnixartUI` на первом доступном iPhone (4 XCUITest-сценария) →
  артефакт **`ui-tests-xcresult`** (7 дней, грузится при любом исходе).

**`release.yml`** — по тегу `v*` (например `v1.0.0`, `v1.2.3-beta`): тот же неподписанный
архив и `.ipa`, артефакт + публикация в GitHub Release через `softprops/action-gh-release@v2`
(`name: Anixart <тег>`, `generate_release_notes: true`); нужны права `contents: write`.
Тегов в репозитории пока нет, workflow ни разу не запускался.

```bash
git tag v1.0.0
git push origin v1.0.0        # запустит release.yml
```

**`screenshots.yml`** — ручная сборка + установка в симулятор + 7 скриншотов
(онбординг, релиз, поиск, главная, коллекция, настройки, история) в артефакт
`ui-screenshots`; подробности — [docs/TESTING.md](TESTING.md#26-скриншоты-в-симуляторе--screenshotsyml).

**Запуск и скачивание из CLI:**

```bash
gh workflow run build.yml --ref main     # или кнопка Actions → Run workflow
gh run list --workflow=build.yml
gh run watch <run-id>
gh run view <run-id> --log
gh run download <run-id> -n Anixart-unsigned-ipa -D out
gh run download <run-id> -n ui-screenshots -D shots
gh run download <run-id> -n ui-tests-xcresult -D ui
```

macOS-минуты на бесплатном плане считаются с коэффициентом **×10** (приватный репозиторий),
поэтому job `ipa` и `uitests` запускаются только по кнопке, а `screenshots.yml` — только
вручную.
Публичный репозиторий — стандартные раннеры бесплатны. Подписанного архива из CI не будет:
нужны сертификат, профиль и платный Developer Program, которых в workflow нет. Версия
Xcode на раннере не фиксирована (не выбирается `xcode-select`) — это ещё одна причина
смотреть лог `ios` после изменений.

## 4. Подпись

| | Бесплатный Apple ID (Personal Team) | Apple Developer Program |
|---|---|---|
| Стоимость | 0 | $99/год |
| Срок жизни сборки | **7 дней**, потом переподпись | 1 год, пока продлевается |
| TestFlight / App Store | нет | да |
| Push, background, App Groups | нет | да |
| Ad Hoc (100 устройств на тип) | нет | да |
| Лимиты Apple | до 3 приложений на устройстве, ~10 новых App ID в неделю | таких лимитов нет |

* **Автоматическая подпись**: Xcode → *Signing & Capabilities* → Team + «Automatically
  manage signing»; Xcode создаёт сертификат *Apple Development*, регистрирует устройство
  и выпускает managed profile (`~/Library/MobileDevice/Provisioning Profiles`).
* Bundle id — `com.swiftsoft.anixart.ios` (префикс `com.swiftsoft`); для личной сборки
  лучше свой reverse-DNS. После смены обновите service в Keychain (`TokenStore.swift`).
* Team в CLI: `xcodebuild ... DEVELOPMENT_TEAM=XXXXXXXXXX -allowProvisioningUpdates`.
  `./tools/check.sh device` без Team упадёт с «Signing for "Anixart" requires a
  development team», потому что проект создаётся заново. Постоянное решение —
  `settings.base.DEVELOPMENT_TEAM` в `project.yml` (сейчас ключа нет).
* Entitlements не нужны (файла нет): Keychain работает в access group по умолчанию.
  Associated Domains не настроен, поэтому universal links (`https://anixart.link/...`)
  не открывают приложение — работает только кастомная схема `anixart://`.
* Истёк сертификат/профиль → «certificate expired», лечится повторным Run из Xcode.

## 5. Установка на устройство

**Готовый `.ipa`.** Артефакт `Anixart-unsigned-ipa` из свежего прогона `build.yml`
(*Actions* → **build** → *Run workflow* → дождаться job `ipa`) или файл из GitHub Release
(тег `v*`). `.ipa` не подписан — подпись делает Sideloadly/AltStore.

**Sideloadly (Windows/macOS, бесплатный Apple ID).** Подключить iPhone по кабелю,
перетащить `.ipa`, вписать Apple ID (понадобится 2FA и app-specific password), Start:
утилита подписывает приложение вашим Apple ID и устанавливает его. На iPhone: iOS 16+ —
включить *Settings → Privacy & Security → Developer Mode* и перезагрузить; доверять
разработчику — *Settings → General → VPN & Device Management → Apple Development → Trust*.
Срок — **7 дней** на бесплатном Apple ID (дальше переподписать), 1 год — платный
Developer Program; лимит — до 3 приложений на устройстве.

**AltStore.** Подписывает так же вашим Apple ID и переподписывает автоматически, пока
AltServer запущен в той же сети; нужен macOS/Windows-хост и `.ipa` из артефакта.

**Xcode (быстрее всего).** Подключить iPhone, выбрать в схеме, Run (см. раздел 2).
Через 7 дней сборка перестаёт запускаться — нужен повторный Run.

**TestFlight (только платный аккаунт).** *Product → Archive* → *Distribute App →
App Store Connect* (или Transporter); `CURRENT_PROJECT_VERSION` должен расти при каждой
загрузке. Внутренние тестеры — до 100 аккаунтов команды без бета-ревью; внешние — до
10 000, первая сборка проходит Beta App Review; сборка живёт 90 дней. Для текущего
приложения это публикация стриминга нелегального контента — см. раздел 6.

Собрать `.ipa` вручную:

```bash
cd ios && xcodegen generate
xcodebuild -project Anixart.xcodeproj -scheme Anixart -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/Anixart.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" archive
mkdir -p build/Payload && cp -R build/Anixart.xcarchive/Products/Applications/Anixart.app build/Payload/
cd build && zip -qry Anixart-unsigned.ipa Payload
```

Не используйте чужие корпоративные сертификаты и не раздавайте сборки массово:
такие сертификаты Apple отзывает, а аккаунт за злоупотребление могут заблокировать.

## 6. App Store: почему нельзя

Текущее приложение — независимый клиент к неофициальному API Anixart, который
проигрывает лицензионное аниме через сторонние плееры (Kodik и т.п.). Для App Review
это два блокирующих пункта:

* **Правило 5.2 (Intellectual Property).** Нельзя использовать чужой контент без
  разрешения правообладателя, а здесь без разрешения используются видео, постеры,
  названия, описания и сам бренд Anixart. «Видео отдаёт сторонний сервис» не снимает
  ответственность: приложение — точка доступа к контенту.
* **Правило 4.2 (Minimum Functionality).** Если убрать стриминг и оставить каталог,
  приложение легко превращается в «обёртку сайта» и отклоняется как недостаточно
  функциональное; один нативный UI этого не гарантирует.

Риски: отказ на ревью — не блокировка, но повторные попытки с «переодетым» приложением
повышают шанс эскалации вплоть до **блокировки аккаунта разработчика** (взнос $99
не возвращается); жалобы правообладателей (DMCA) ведут к снятию приложения и блокировке
неофициального API; TestFlight правила не обходит — сборки удаляются, ссылки проверяются.
Вне Apple тоже есть риск: распространение такого клиента — распространение доступа
к пиратскому контенту.

**Легальные альтернативы** (реалистичный путь, если нужен магазин):

* Только каталог/трекер: метаданные (название, жанры, рейтинг, статус), свои описания
  и обзоры, списки просмотра, напоминания, статистика.
* Ссылки только на официальные площадки (Crunchyroll, Netflix, Amazon Prime Video,
  Hulu, Кинопоиск, Wink, KION, Start и т.п.); видео открывается в их приложении/сайте.
* Убрать: встроенный WKWebView-плеер и `episode/target`, скачивание серий, обход
  геоблокировок и рекламы, постеры без лицензии, бренд Anixart в имени и иконке,
  авторизацию в неофициальном API (это ещё и 5.1.1 — сбор персональных данных
  третьей стороной без политики конфиденциальности).
* Для любой подачи нужны App Privacy, политика конфиденциальности, support URL и
  Privacy Manifest (раздел 8). Это не юридическая консультация — нужен юрист.

## 7. Чек-лист перед первой сборкой

```bash
xcodebuild -version             # Xcode 15.x / 16.x
xcode-select -p                 # /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept # один раз после установки
brew list --versions xcodegen   # или xcodegen --version
```

| # | Проверка | Как проверить | Ожидаемо |
|---|---|---|---|
| 1 | `projectFormat: xcode15_0`, `xcodeVersion: "15.0"` | `ios/project.yml` | Xcode 14 проект не откроет; 15/16 — без предупреждений о формате |
| 2 | Схема `Anixart` shared | `cd ios && xcodegen generate && xcodebuild -list -project Anixart.xcodeproj` | в списке `Schemes: Anixart`; ось `test` содержит `AnixartTests` (без блока `schemes` `xcodebuild -scheme` падает) |
| 3 | `Info.plist` генерируется | `ios/Anixart/Resources/Info.plist` после `xcodegen generate` | создан из блока `info:`; в `sources` исключён — руками не править, перезапишется |
| 4 | Фоновое аудио плеера | `plutil -p ios/Anixart/Resources/Info.plist \| grep -A2 BackgroundModes` | `UIBackgroundModes: [audio]` — нужно для фона/PiP нативного плеера |
| 5 | Deep links | `plutil -p ...Info.plist \| grep -A5 URLTypes` | `CFBundleURLSchemes: [anixart]`; Associated Domains нет — universal links не работают |
| 6 | Иконка на месте | `sips -g pixelWidth -g pixelHeight -g hasAlpha .../AppIcon.appiconset/icon-1024.png` | 1024×1024, без альфа-канала (App Store не принимает прозрачность); `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` |
| 7 | ATS | `plutil -p ...Info.plist \| grep -A2 Transport` | `NSAllowsArbitraryLoads: true` — нужно для чужих страниц в WKWebView; для App Store требует обоснования, лучше сузить до `NSExceptionDomains` |
| 8 | Team и bundle id | Xcode → *Signing & Capabilities* | Team выбрана, `com.swiftsoft.anixart.ios` зарегистрирован, ошибок подписи нет |
| 9 | Версия и build | `project.yml`: `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` | 1.0 / 1; build увеличивать перед каждой загрузкой в TestFlight |
| 10 | Сборка | `cd ios && ./tools/check.sh` | `OK`; для устройства — `./tools/check.sh device` |
| 11 | Контракт API | `cd ios && python3 tools/api_probe.py` | 13 живых проверок проходят |
| 12 | Юнит-тесты | `xcodebuild test -project Anixart.xcodeproj -scheme Anixart -destination 'platform=iOS Simulator,name=iPhone 15'` | `Executed 57 tests, with 0 failures` (в CI — первый доступный симулятор) |
| 13 | Лишние ключи | Info.plist: `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` | объявлены, но смена аватара не реализована — при ревью лучше убрать |
| 14 | Privacy Manifest | `find ios -name 'PrivacyInfo.xcprivacy'` | файл есть (`ios/Anixart/Resources/PrivacyInfo.xcprivacy`, коммит `a901dc8`), но сборкой/валидацией ещё не проверен — см. раздел 8 |

UI-тесты (по желанию/для навигации): `xcodebuild test -project Anixart.xcodeproj -scheme
AnixartUI -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO` —
4 смоук-сценария; в CI — job `uitests` (вручную), см. [docs/TESTING.md](TESTING.md#27-ui-тесты-в-симуляторе--iosanixartuitests).

## 8. Privacy Manifest (PrivacyInfo.xcprivacy) — состояние и TODO

**Статус на 24.11.2026:** файл `ios/Anixart/Resources/PrivacyInfo.xcprivacy` есть в
репозитории (коммит `a901dc8`); в `ios/project.yml` отдельной записи не требует —
XcodeGen подхватывает его как ресурс из `sources: Anixart`. **TODO:** прогнать
`xcodegen generate` + `xcodebuild`, убедиться, что файл попал в `.app` как ресурс (и что
сборка не ругается на дубль/формат), затем сверить содержимое с App Privacy в
App Store Connect. Для сайдлоада он не нужен; для загрузки в App Store Connect (включая
TestFlight) Apple требует манифест с 1 мая 2024.

Содержимое текущего файла (по `plutil`/тексту):

* `NSPrivacyTracking` = `false`, `NSPrivacyTrackingDomains` = `[]`: рекламы, аналитики и
  трекинга нет, AppTrackingTransparency не требуется.
* `NSPrivacyCollectedDataTypes` — `UserID` (id/логин профиля при входе), linked,
  purpose `AppFunctionality`. **TODO:** добавить `SearchHistory` (поисковые запросы уходят
  в сторонний API) и сверить с App Privacy в App Store Connect.
* `NSPrivacyAccessedAPITypes` — только `UserDefaults` (`Session.swift`,
  `PlaybackProgress.swift`, `VideoQuality.swift`), причина `CA92.1`. Keychain, `URLSession`
  и `WKWebView` в список не входят; при появлении `FileManager`-таймстемпов — `C617.1`,
  проверок диска — `E174.1`, системного времени — `35F9.1`.
* Сторонних SDK нет, их манифесты не нужны. `App Store Connect → App Privacy` должен
  совпадать с манифестом; добавьте privacy policy и support URL. В Info.plist стоит
  добавить `ITSAppUsesNonExemptEncryption = false` (ключа нет), иначе экспорт-комплаенс
  придётся подтверждать при каждой загрузке — шифрование здесь только HTTPS.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key><array/>
    <key>NSPrivacyCollectedDataTypes</key><array><dict>
        <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeUserID</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict></array>
    <key>NSPrivacyAccessedAPITypes</key><array><dict>
        <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
        <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array>
    </dict></array>
</dict></plist>
```
