# Статус проекта Anixart iOS

Снимок на 24.11.2026, коммит `e6b7c3f`. Здесь — что реально проверено, чем именно и что осталось.
CI заблокирован биллингом GitHub Actions: как проверять без него — в
[LOCAL_VERIFICATION.md](LOCAL_VERIFICATION.md).

## Что это

Независимый iOS-клиент (SwiftUI, iOS 16+) к тому же неофициальному API, что и Android-приложение
Anixart 11 beta. Собирается в GitHub Actions на macOS-раннере, распространяется как
неподписанный IPA через Sideloadly. App Store невозможен (правило 5.2).

## Как поставить на iPhone

1. Скачать IPA из [релизов](https://github.com/xeho11/anixart-ios/releases) (последний тег).
2. Sideloadly: перетащить IPA → Apple ID → Start.
3. На телефоне: доверить профиль разработчика, включить «Режим разработчика» (iOS 16+).
4. Бесплатный Apple ID — 7 дней подписи, затем повторить.

## Проверено (с доказательствами)

| Что | Как проверено | Результат |
|---|---|---|
| Сборка под Xcode | job `ios` в CI на macos-15 | ✅ `BUILD SUCCEEDED` (до добавления видео/площадок — см. «Не проверено») |
| Юнит-тесты | `xcodebuild test` в CI + Linux-стенд | ✅ **68/68 тестов исполнены и прошли на Linux** (7 файлов, `ios/tools/LinuxTestRunner.md`); под Xcode последний прогон — 62 теста, 0 падений (до видео-тестов) |
| UI-тесты | job `uitests` (симулятор) | ✅ **5 тестов**: онбординг→таббар, главная, deep link релиза, плеер открывается, поиск «naruto» |
| Видео релиза | стаб-стенд (typecheck на CE) + `ReleaseVideoTests` **6/6** на Linux | ⚠️ под Xcode не собиралось (видео и площадки); скриншоты `11-video-youtube`/`12-video-vk` не снимались |
| AniLibria | скриншот CI `09-player-native.png` | ✅ **видео играет** (AVPlayer + HLS) |
| AnixPlayer/StudioMir | скриншот CI `10-player-anixplayer.png` | ✅ **видео играет** (AVPlayer + HLS) |
| Kodik | скриншот `08-player.png` + 7 живых запросов | ⚠️ плеер открывается, прокси работает, но **Kodik отвечает «Error code: ds»** — отказ на стороне Kodik |
| Sibnet | живые запросы | ⚠️ источники есть, но `episode/target` для них отдаёт пустой эпизод |
| RuTube | ручная проверка API | ⚠️ цепочка `api/play/options → m3u8 (200)` рабочая, но в 50 просмотренных релизах источника RuTube нет |
| YouTube | анализ APK | ⚠️ в конвейере серий не используется (только встроенные видео) |
| Поиск, релиз, коллекции, история, настройки | скриншоты CI | ✅ реальные данные с API |
| Контракт API | `tools/api_probe.py` | ✅ 13/13 |

## Реализовано

**Экраны (19):** Главная (полки, баннеры, «Продолжить просмотр»), Поиск (релизы/коллекции/люди +
фильтры), Страница релиза (метаданные, жанры, описание, комментарии, серии, действия:
список/избранное/оценка/поделиться, скачивание), Плеер (6 провайдеров, качество, PiP, фон,
AirPlay, «следующая серия», автоподбор источника), Коллекции (хаб + детали), Комментарии,
История, Избранное, Профиль, Чужой профиль, Настройки (статус, темы, тумблеры), Загрузки,
Вход (логин/пароль + QR), Онбординг, Статьи (+ читалка), Уведомления, Друзья.

**Инфраструктура:** APIClient (форма-логин + `?token=`, ретраи с backoff, 0-based пагинация),
Keychain, дисковый кэш картинок, офлайн-кэш каталога/истории, офлайн-скачивание HLS
(`AVAssetDownloadURLSession`), deep links (`anixart://...`), Privacy Manifest, скелетоны,
автоподбор рабочего источника (`SourceFallbackService`; покрыт `FallbackTests`, 5 тестов:
порядок кандидатов, распознавание ошибок провайдера, подсказки причин, прокси-цели).

**Видео релиза:** секция «Видео» на странице релиза — `GET video/release/{id}`
(трейлеры, превью, опенинги, эндинги, клипы; блоки по категориям, `last_videos`) и
встраивания **YouTube** (iframe-плеер по `youtubeID`), **VK** и **RuTube** (web-плеер);
секция «Смотреть легально» — официальные площадки релиза
(`release/streaming/platform/{id}`, например Netflix), ссылки открываются в Safari.
Отладочный запуск `-anixart-open-video=<releaseId>/<videoId>`, скриншоты
`11-video-youtube.png` / `12-video-vk.png` в `screenshots.yml`. Поле `hosting` приходит
и объектом `{id,name,icon}`, и строкой — декодируется терпимо (`VideoHostingRef`), иначе
падал бы любой релиз с видео; тесты — `ReleaseVideoTests` (6).

**CI:** `build.yml` (core/ios/ipa/uitests), `release.yml` (по тегу → GitHub Release с IPA),
`screenshots.yml` — теперь **12 PNG** (01–12: 3 плеера и 2 видео). Последний зафиксированный
зелёный прогон был до видео-скриншотов; `11-video-youtube`/`12-video-vk` добавлены позже
и ещё не снимались — Actions заблокирован (см. ниже).

## CI: работает через публичное зеркало

Основной репозиторий (приватный) исчерпал бесплатные минуты GitHub Actions — macOS-раннеры
тарифицируются ×10. Решение: **публичный CI-репозиторий**
[`iasjg9a4a/anixart-ios`](https://github.com/iasjg9a4a/anixart-ios) — на публичных
репозиториях Actions бесплатны, включая macOS.

Синхронизация — одним срезом кода без истории (`tools/mirror_to_ci.py`), запуск проверок —
`tools/ci_push.ps1`:

```bash
python tools/mirror_to_ci.py --remote https://github.com/iasjg9a4a/anixart-ios.git
gh workflow run build.yml --repo iasjg9a4a/anixart-ios --ref main
```

Проверено 24.11.2026 на публичном CI (run 45315478576):

| Job | Результат |
|---|---|
| Ядро (Linux, Swift) | ✅ |
| Сборка iOS (macos-15) | ✅ |
| Юнит-тесты | ✅ **68/68**, 0 падений (27,6 с) |
| UI-тесты (симулятор) | ✅ **5/5** (онбординг, главная, релиз, плеер, поиск) |
| Неподписанный IPA | ✅ артефакт 1,6 МБ |

## Не проверено / риски

1. **Xcode-компиляция новых файлов видео и фолбэка не прогонялась** — CI недоступен:
   `ReleaseVideoModels`, `ReleaseVideosSection`, `APIClient+Videos`, `SourceFallbackService`,
   `APIClient+Streaming`, `ReleaseStreamingSourcesSection` проверены только стаб-стендом
   (typecheck через Compiler Explorer) и Linux-тестами; сборка под iOS SDK, `@available`
   и актор-изоляция — нет. Первое, что нужно прогнать при восстановлении Actions (или на Mac).
2. **68 юнит-тестов под Xcode не прогонялись**: последний зафиксированный Xcode-прогон —
   62 теста (до `ReleaseVideoTests`). Взамен все 68/68 исполнены на Linux через Compiler
   Explorer, но это Linux Foundation, а не XCTest под iOS.
3. **На реальном iPhone ничего не запускалось** — только симулятор CI.
4. Kodik: на нашей сети отказ; нужна проверка на сети пользователя. Автоподбор переключит
   на рабочий источник, если он есть у релиза.
5. Sibnet: 403 из нашего региона; форма ответа `episode/target` пустая — возможно, источник
   отключён на сервере.
6. Офлайн-скачивание: код есть, на устройстве не проверялось (перенос `.movpkg` из
   `didFinishDownloadingTo` Apple не рекомендует — проверить воспроизведение).
7. Push-уведомления, реклама Kodik, `config/toggles`, запись настроек — не реализованы.
8. Universal links требуют Associated Domains entitlement — не настроено.

## Обновление и выпуск

```bash
git tag v0.1.5 && git push origin v0.1.5   # release.yml соберёт IPA и опубликует
```

Пока Actions заблокирован (см. выше), тег создать можно, но IPA не соберётся — это
ограничение биллинга, а не workflow.

Документы: [LOCAL_VERIFICATION.md](LOCAL_VERIFICATION.md) · [PLAYERS.md](PLAYERS.md) ·
[API.md](API.md) · [ARCHITECTURE.md](ARCHITECTURE.md) ·
[TESTING.md](TESTING.md) · [RELEASE.md](RELEASE.md) · [OFFLINE.md](OFFLINE.md) ·
[SDK_CROSSCHECK.md](SDK_CROSSCHECK.md) · [STYLE.md](STYLE.md)
