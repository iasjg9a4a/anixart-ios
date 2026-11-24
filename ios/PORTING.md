# Anixart → iOS: разбор и план порта

Короткий ответ: **да, переписать можно, но это не «конвертация» — это написание нового
приложения с нуля**. Ниже — что реально лежит в APK, что я проверил на живом бэкенде,
что уже сделано в этой папке и сколько это займёт.

---

## 1. Что внутри APK

Файл: `../anixart_11-beta-3.apk` — 19 056 967 байт (~18,2 МиБ), 3468 записей в zip.

| Признак | Значение |
|---|---|
| package | `com.swiftsoft.anixartd` |
| label | Anixart |
| Язык | Kotlin (нативный Android) |
| UI | Jetpack Compose + Epoxy + Moxy (фрагменты) |
| DI | Hilt / Dagger |
| Сеть | Retrofit + OkHttp + Jackson + kotlinx.serialization |
| БД | Room |
| Видео | AndroidX Media3 / ExoPlayer (`assets/shaders/*.glsl`) |
| Прочее | Glide, VK ID, Yandex Ads/Auth, AppMetrica, Firebase, ru.ok.tracer, jsoup |
| Код | 4 dex: 9,5 / 0,6 / 10,1 / 3,5 МБ |
| Нативные либы | только `libandroidx.graphics.path.so` и `libmedia_codec.so` (4 ABI) |

Активности: `StartActivity`, `AuthActivity`, `MainActivity`, `TelegramAuthActivity`,
`SwiftPlayerActivity`, `WebPlayerActivity`, `EmbedActivity`, `KodikAdActivity`,
`UpdateActivity`, сервис загрузок `EpisodeDownloadService`.

**Вывод:** никакого Flutter / React Native / Kotlin Multiplatform здесь нет. Общего
кода между Android и iOS не существует, поэтому «портировать» можно только продукт
(UX + API), а не байты.

## 2. Бэкенд

Хост берётся из dex: `https://api-s.anixsekai.com/` (в APK также встречаются
`anixart-app.com`, `editor.anixsekai.com`, `api.studiomir.club` — это веб/редактор/реклама,
не API приложения).

В dex ~43 Retrofit-интерфейса (`network/api/AuthApi`, `ReleaseApi`, `SearchApi`, `ProfileApi`,
`EpisodeApi`, `CollectionApi`, `FeedApi`, `NotificationApi`, `FilterApi`, `DiscoverApi` и т.д.),
из них вытащено ~300 путей. Ключевые проверены живыми запросами:

| Метод | Путь | Авторизация | Что отдаёт |
|---|---|---|---|
| GET | `release/{id}` | нет | полный релиз, 79 полей |
| GET | `profile/{id}` | нет | профиль, 93 поля |
| GET | `filter/{page}` | нет | каталог, 25 на страницу |
| GET | `discover/hub` | нет | «смотрят», «обсуждают», коллекции |
| GET | `collection/hub` | нет | коллекции |
| GET | `type/all` | нет | 402 озвучки |
| POST | `search/releases/{page}` | нет | поиск, тело `{"query": "..."}` |
| GET | `episode/{releaseId}` | нет | озвучки релиза |
| GET | `episode/{releaseId}/{typeId}` | нет | источники (Kodik, Sibnet…) |
| GET | `episode/{releaseId}/{typeId}/{sourceId}` | нет | список серий |
| GET | `episode/target/{releaseId}/{sourceId}/{position}` | нет | серия + подписанная ссылка на плеер |
| GET | `episode/watch/{...}` | **да** | отметка просмотра |
| GET | `profile/info`, `profile/list/all/{status}/{page}` | **да** | мои данные и списки |
| POST | `auth/signIn`, `auth/signUp` | — | токен |

Проверено вживую (см. `tools/api_probe.py`): анонимно работают каталог, поиск, страница
релиза, список серий и **получение ссылки на видео** — `episode/target/…` вернул рабочий
URL Kodik (`iframe: true`). Ссылка подписана по IP и времени, поэтому её нужно запрашивать
непосредственно перед показом.

### Авторизация: разгадана

`POST auth/signIn` отвечает `200` с пустым телом **только на JSON**. Оригинальное приложение
шлёт обычную форму:

```
POST https://api-s.anixsekai.com/auth/signIn
Content-Type: application/x-www-form-urlencoded

login=<логин>&password=<пароль>
```

Проверено на живом API 24.11.2026: та же пара логин/пароль формой даёт
`{"code":3,"profile":null,"profileToken":null}` — то есть тело разобрано, это просто
«неверная пара». Коды: `0` — успех (`profile` + `profileToken`), `2` — логин короче 3 или
длиннее 20 символов, `3` — неверный логин или пароль (анти-энумерация).

Подписи, device-id и капчи в логине **нет**: все `hmac/sha256/recaptcha` в dex принадлежат
Firebase, Tink и VK ID, а единственный interceptor Retrofit — подстановка токена.
20+ вариантов заголовков и query-параметров ответ не меняли.

Запасной путь — QR-вход: `auth/qr/create` → `auth/qr/status` → `auth/qr/open`
(работает без пароля, отдаёт `key`, `secret`, `pin`, `poll_interval`).

Что реализовано: `APIClient.signIn` собирает форму, разбирает коды и кладёт токен в Keychain.
Что ещё не проверено: успешный вход реальным аккаунтом (учётных данных нет) и имя заголовка
с токеном — `token` или `Authorization: Bearer` подтвердится только на защищённом эндпоинте.

Следствия:
* чтение (каталог, поиск, страница, серии, видео, комментарии) — работает без входа;
* списки, история, «смотрю/просмотрено», синхронизация прогресса — после входа,
  который теперь реализован и ждёт проверки на устройстве.

## 3. Что уже сделано в этой папке

```
ios/
  project.yml                     # проект для XcodeGen (iOS 16+, без внешних зависимостей)
  Anixart/
    App/                          # точка входа, сессия, тема
    Core/                         # APIClient, TokenStore (Keychain)
    Models/                       # Codable-модели под реальные ответы сервера
    Components/                   # постеры, полки, чипы, состояния загрузки
    Features/Home|Search|Release|Player|Profile|Collections|Comments/
  tools/api_probe.py              # проверка контракта API на живом сервере
```

Реализовано: каталог/главная (полки «Сейчас смотрят», «Обсуждают», «Новинки»), поиск
с дебаунсом, страница релиза (постер, метаданные, жанры, описание, связанные, комментарии),
выбор озвучки → источника → серии, плеер (WKWebView для Kodik-iframe и AVPlayer для
прямых `m3u8`/`mp4`), коллекции (хаб + каталог), отдельный экран комментариев с пагинацией,
профиль с формой входа (form-urlencoded) и списками, тёмная тема.

Инструменты проверки:

* `tools/api_probe.py` — 13 живых проверок контракта API (все проходят на 24.11.2026);
* `tools/fetch_fixtures.py` + `tools/ModelCheck/main.swift` — офлайн-проверка Codable-моделей
  на реальных ответах, без Xcode (`swiftc -o modelcheck Anixart/Models/Models.swift tools/ModelCheck/main.swift`);
* `tools/StubSwiftUI/check.py` — typecheck всех SwiftUI-экранов через Compiler Explorer
  с заглушками SwiftUI/WebKit/AVKit (стенд самопроверяется мутациями);
* `tools/check.sh` — сборка на macOS одной командой.

**Важно:** ядро (модели, API-клиент, ModelCheck) и **экраны** (через заглушки) проверены
настоящим компилятором Swift 6.4 — 0 ошибок. Это не заменяет сборку под iOS SDK:
актор-изоляцию под Xcode 15, доступность API iOS 16 и поведение SwiftUI проверяет только
`xcodebuild`. Локальный Swift-тулчейн на Windows не запускается (падает в mimalloc).

Не реализовано (осознанно): статьи/лента, уведомления, друзья, офлайн-загрузки,
смена аватарки, настройки.

## 4. Почему это нельзя «просто собрать под iOS»

1. **Swift/UIKit/SwiftUI ≠ Kotlin/Compose.** Переписывается каждый экран, каждая
   ViewModel, навигация, кэш, загрузки.
2. **Нужен macOS + Xcode.** На Windows iOS-приложение не собрать и не запустить:
   нет тулчейна, симулятора и подписи. Варианты: Mac (даже старый Mac mini), облачный
   Mac (MacinCloud/MacStadium), либо CI на `macos-14` раннерах GitHub Actions
   (сборка — да, но подпись и установка на устройство всё равно требуют Apple ID/сертификат).
3. **Публикация.** Anixart — неофициальный агрегатор аниме-контента; в App Store такое
   приложение не пройдёт ревью (правила 4.2 «minimum functionality» и 5.2 «intellectual
   property»), да и правообладатели против. Реалистичный путь — личная сборка/сайдлоад:
   AltStore/Sideloadly + бесплатный Apple ID (переподпись раз в 7 дней) или платный
   Developer Program ($99/год, 1 год на сборку).

## 5. Оценка работ

| Этап | Содержание | Оценка |
|---|---|---|
| 1. Каркас + API | модели, клиент, тема, навигация | 3–5 дней |
| 2. Каталог/поиск/релиз | список, фильтры, карточка, связанные | 1–2 недели |
| 3. Плеер | web-плеер, выбор озвучки/источника, прогресс | 1 неделя |
| 4. Авторизация | реверс подписи/капчи, Keychain, сессия | 1–2 недели (риск) |
| 5. Аккаунт | списки, история, синхронизация прогресса | 1–2 недели |
| 6. Соцчасть | комментарии, коллекции, лента, уведомления | 3–4 недели |
| 7. Офлайн | загрузки серий, кэш, фоновая докачка | 1–2 недели |
| 8. Полировка | анимации, пустые состояния, локализация, иконки | 1–2 недели |

MVP (пункты 1–3, без аккаунта) — примерно **3–4 недели** одного разработчика.
Паритет с Android — **3–6 месяцев**.

## 6. Как собрать то, что уже есть

На Mac:

```bash
brew install xcodegen
cd ios
xcodegen generate
open Anixart.xcodeproj
```

В Xcode: выбрать свою Team в *Signing & Capabilities*, подключить iPhone, Run.
Минимальная версия — iOS 16. Внешних зависимостей (SPM/CocoaPods) нет.

Проверить, что бэкенд жив и контракт не поменялся:

```bash
python tools/api_probe.py
```

## 7. Юридическая оговорка

Код в этой папке — независимая реализация клиента, которая обращается к тому же
неофициальному API, что и APK. Права на контент (аниме, постеры, озвучки) принадлежат
правообладателям; распространение такого клиента в магазинах приложений и публичное
развёртывание могут нарушать и их права, и правила магазинов. Используйте для личных
целей.
