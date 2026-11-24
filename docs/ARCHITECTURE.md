# Архитектура iOS-клиента Anixart

Документ описывает устройство SwiftUI-клиента в каталоге `ios/` репозитория Anixart:
слои, зависимости, экраны, авторизацию, плееры, кэши, обработку ошибок и инструменты
проверки. Все пути — относительные от корня репозитория.

Снимок кода: **24.11.2026**, коммит `7b4703e`. В `ios/Anixart` — 53 Swift-файла
(~15 600 строк); тесты — `ios/AnixartTests` (5 файлов, 57 юнит-тестов) и
`ios/AnixartUITests` (1 файл, 4 UI-теста). Рабочее дерево активно пополняется, поэтому
перед правками сверяйтесь с исходниками.

Связанные документы: `ios/PORTING.md` (разбор APK и план порта), `ios/ROADMAP.md`
(паритет функций), `ios/README.md` (сборка и ограничения), `docs/PLAYERS.md` (плееры),
`docs/API.md` (API), `docs/TESTING.md` (уровни проверки), `docs/STYLE.md` (стиль кода).

## 1. Обзор и принципы


Независимый iOS-клиент к неофициальному API Anixart — тому же бэкенду
(`https://api-s.anixsekai.com/`), с которым работает Android-приложение Anixart 11 beta.
Общего кода с Android нет: это отдельная реализация продукта (см. `ios/PORTING.md`).

| Параметр | Значение | Где зафиксировано |
|---|---|---|
| Платформа | iOS 16.0+, iPhone/iPad | `ios/project.yml` |
| Язык/SDK | Swift 5.9, Xcode 15, `SWIFT_STRICT_CONCURRENCY: minimal` | `ios/project.yml` |
| Зависимости | нет (Foundation, SwiftUI, WebKit, AVKit, Security, UIKit) | `ios/README.md` |
| Сборка | XcodeGen: `xcodegen generate` → `Anixart.xcodeproj` | `ios/project.yml`, `ios/tools/check.sh` |
| Тема | только тёмная (`UIUserInterfaceStyle: Dark`) | `ios/project.yml`, `App/AnixartApp.swift` |
| Навигация | 5 табов `TabView` + `NavigationStack`/`NavigationLink`, модальные `sheet`/`fullScreenCover` | `ios/Anixart/Features/` |
| `Info.plist` | генерируется XcodeGen из `project.yml`: `UIBackgroundModes: [audio]`, `CFBundleURLTypes` (схема `anixart`), `NSAllowsArbitraryLoads: true`, портрет + 2 ландшафта, camera/photo usage | `ios/project.yml` |
| Privacy Manifest | `ios/Anixart/Resources/PrivacyInfo.xcprivacy` (с коммита `a901dc8`) | ресурс цели `Anixart` |

Принципы, которых придерживается код:

* **MVVM без фреймворков:** на экран — `View` + `@MainActor final class *ViewModel:
  ObservableObject` в одном файле; состояние живёт только во VM.
* **Сеть — только через `APIClient`:** единственное место с `URLSession`, путями и разбором кодов.
* **Ошибки — данные, а не исключения:** VM ловит `APIError` в `@Published errorMessage`.
* **Модели — «глупые» Codable-структуры** без сети и UI (форматирование — их свойства).
* **Общие кирпичи — в `Components/` и `Theme`;** комментарии и UI-строки — на русском.

## 2. Слои и зависимости

### 2.1 Слои

| Слой | Файлы | Ответственность | Импортирует |
|---|---|---|---|
| Models | `ios/Anixart/Models/Models.swift` (~750 строк) | Codable-модели ответов, справочники (`ProfileListStatus`, `VideoProvider`), обёртки `*Response` с `code`, `Paged<Item>`; вычисляемые свойства для UI | Foundation |
| Core: транспорт | `Core/APIClient.swift` + расширения `Core/APIClient+Actions/Articles/Feed/Friends/Notifications/Preferences.swift` | базовый URL, `URLSession` (таймауты 25/40 с), 50+ методов, `request<T>`, `check(code:)`, повторы GET, `signIn`, `APIError` | Foundation (+ `FoundationNetworking` на Linux) |
| Core: авторизация | `Core/TokenStore.swift` | токен в Keychain (`service = com.swiftsoft.anixart.ios`, `account = auth-token`) | Foundation, Security |
| Core: инфраструктура | `Core/RetryPolicy.swift`, `OfflineCache.swift`, `OfflineIntegration.swift`, `ImageCache.swift` | ретраи с экспоненциальной паузой; дисковый JSON-кэш и его интеграция; кэш картинок память→диск→сеть | Foundation; `ImageCache` — ещё SwiftUI/UIKit |
| App | `App/AnixartApp.swift`, `Session.swift`, `Theme.swift`, `DeepLinkRouter.swift`, `DeepLinkDestination.swift` | `@main`, `RootView` (онбординг/`TabView`/deep links), глобальное состояние аккаунта, палитра, разбор и показ маршрутов | SwiftUI, Combine |
| Components | `Components/Components.swift`, `SkeletonViews.swift` | `RemoteImage` (через `ImageCache`), `ReleasePoster`, `ReleaseCard`, `ShelfView`, `ChipView`, `LoadingView`, `ErrorStateView`, скелетоны | SwiftUI |
| Features | `Features/<Feature>/*.swift` | 18 подключённых экранов + плеерный слой; экран и его VM в одном файле | SwiftUI, AVKit, WebKit |
| Tests | `ios/AnixartTests/*.swift` (5 файлов) + `ios/AnixartUITests/SmokeUITests.swift` | XCTest: модели, API-клиент, инфраструктура, плеер, резолверы; XCUITest: смоук-сценарии запуска/навигации | XCTest, XCTest UI |

Иконка, `AccentColor` и ресурсы лежат в `ios/Anixart/Resources/` (`Info.plist` и
`PrivacyInfo.xcprivacy` — там же; первый генерируется XcodeGen из `project.yml`).

### 2.2 Схема зависимостей (по реальным файлам)

```
Models/Models.swift (Foundation) ──► Core/APIClient.swift + APIClient+*.swift
  Release, Profile, Episode, Paged<T>   request<T> → perform → Retry.run (GET) → check
            ▲                                       ▲
            │                          Core/TokenStore.swift (Keychain → ?token=)
            │ URLSession (25/40 с)
            ▼
ViewModel-слой (@MainActor ObservableObject)
  App/Session.swift — аккаунт, вход/выход, профиль
  Features/**/*View.swift — по VM на экран; Player/PlaybackProgress, NextEpisodeService
            │ @Published: данные, isLoading, errorMessage
            ▼
View-слой (SwiftUI): App/AnixartApp.swift → RootView (онбординг → TabView 5 табов)
  Home (+BannerShelf, ContinueWatchingShelf) · Search (+Filters/Collections/Profiles)
  Collections (+Detail) · Articles (+Detail) · Profile (+Login, UserProfile, Settings,
  History, Favorites, Notifications, Friends; Release → Comments / PlayerView)
  DeepLinkDestination — маршрут → экран (sheet в RootView); Components/, Theme
```

Связи, которые важно помнить при правках:

* `Session` зависит от `APIClient`, `TokenStore`, `UserDefaults`.
* `ReleaseView` ↔ `Components` циклически (`ShelfView` → `ReleaseView`), поэтому StubSwiftUI
  компилирует почти все файлы одним блобом.
* Плеерный слой не зависит от SwiftUI: резолверы — чистые типы, `PlaybackProgress` и
  `NextEpisodeService` — `@MainActor`-сервисы без вьюх.
* `ImageCache` — единственный Core-файл с UI-типами; `RemoteImage` грузит через него, а
  готовая `CachedAsyncImage` не вызывается.

### 2.3 Правила слоёв

| Правило | Смысл |
|---|---|
| `View` не знает про сеть и хранилища | нет `APIClient`/`URLSession`/`UserDefaults` во вью (исключения: `SettingsView` читает `Bundle`, deep links читают `ProcessInfo.arguments`) |
| `ViewModel` не импортирует UI-типы | `ObservableObject`/`@Published` — из Combine/SwiftUI, остальное не нужно |
| `Models` зависят только от Foundation | модели собираются `swiftc` без iOS SDK (`ios/tools/core_check.sh`) |
| Сеть — только в `APIClient` | все пути и разбор `code` в одном месте, VM не собирает URL |
| Состояние — только во VM/`Session` | вьюхи — функции от состояния, без собственной сети |
| Палитра и отступы — только через `Theme` | `Theme.accent`, `.cardSurface()`, `.screenBackground()` |

## 3. Экраны и ViewModel

Подключено **18 экранов**: 5 табов + 12 (11 экранов из табов/deep links + QR-вход) +
онбординг; «вход» — состояние «Профиля», а не отдельный экран.

| Экран / роль | ViewModel / состояние | Файл | Точка входа и данные |
|---|---|---|---|
| Приложение, вкладки, онбординг | — / (`@State page`) | `App/AnixartApp.swift`, `Features/Onboarding/OnboardingView.swift` | `@main`; `RootView` показывает онбординг (флаг `anixart.onboarding.done`, 3 страницы) или `TabView` из 5 вкладок |
| Главная (таб) | `HomeViewModel` | `Features/Home/HomeView.swift` | `discover/hub` (`watching/discussing/recommendations/collections`) + `filter/1`; полки, «Загрузить ещё», офлайн-снимок |
| Полки главной | `BannerShelfViewModel`, `ContinueWatchingViewModel` | `Home/BannerShelfView.swift`, `Home/ContinueWatchingShelf.swift` | баннеры `interesting` (10, бейдж «Реклама» при `type == 1`); «Продолжить просмотр» — `PlaybackProgress.continueWatching()` + догрузка `release/{id}` |
| Поиск (таб) | `SearchViewModel`, `SearchSegment` | `Features/Search/SearchView.swift` | `.searchable`, дебаунс 350 мс; пустой запрос — каталог `filter/{page}` с фильтром, текст — 3 сегмента |
| Сегменты и фильтр поиска | `SearchCollectionsViewModel`, `SearchProfilesViewModel`, `SearchFiltersViewModel` | `Search/SearchCollectionsView.swift`, `SearchProfilesView.swift`, `SearchFiltersView.swift` | коллекции `POST search/collections/{page}`, люди `POST search/profiles/{page}` (обе с догрузкой); фильтр — `sheet` с сортировкой/жанрами/годом (`ReleaseFilter.queryItems`) |
| Коллекции (таб) | `CollectionsViewModel` | `Features/Collections/CollectionsView.swift` | `collection/hub` + `collection/all/1`; полки недели/рекомендуем/мои + сетка |
| Коллекция | `CollectionDetailViewModel` | `Features/Collections/CollectionDetailView.swift` | `NavigationLink` из коллекций/главной; `collection/{id}` + `collection/{id}/releases/{page}`, 5 счётчиков |
| Статьи (таб) | `ArticlesFeedViewModel` | `Features/Articles/ArticlesFeedView.swift` | `POST search/feed/{page}`; скелетоны, догрузка |
| Статья | `ArticleDetailViewModel` | `Features/Articles/ArticlesFeedView.swift` | `article/{id}` + `article/comment/all/{id}/1`; блоки `payload.blocks` (header/quote/media/delimiter/paragraph) |
| Профиль (таб) | `Session` + `ProfileListsViewModel` | `Features/Profile/ProfileView.swift` | гость видит `LoginView`, иначе `ProfileContent`: шапка, статистика, плитки, 5 списков `profile/list/all/{status}/{page}` |
| Чужой профиль | `UserProfileViewModel` | `Features/Profile/UserProfileView.swift` | `NavigationLink` из комментариев, друзей, поиска людей; `profile/{id}` |
| Релиз | `ReleaseViewModel` | `Features/Release/ReleaseView.swift` | `release/{id}` + `episode/{id}` параллельно, каскад озвучка → источник → серии, действия, `play()` → `PlaybackRequest` |
| Плеер | — (нет VM) | `Features/Player/PlayerView.swift` | `fullScreenCover` из релиза; web через `PlayerWebView`, HLS/MP4 через `NativePlayerView` |
| Комментарии | `CommentsViewModel` | `Features/Comments/CommentsView.swift` | `sheet` из релиза; `release/comment/all/{id}/{page}`, дедупликация по `id` |
| История | `HistoryViewModel` | `Features/History/HistoryView.swift` | плитка профиля/deep link; `history/{page}`, пагинация, офлайн-снимок |
| Избранное | `FavoritesViewModel` | `Features/Favorites/FavoritesView.swift` | плитка профиля/deep link; `favorite/all/{page}`, пагинация |
| Уведомления | `NotificationsViewModel` | `Features/Notifications/NotificationsView.swift` | плитка профиля; `notification/all/{page}` + `notification/count`, «прочитать все», удаление по одному |
| Друзья | `FriendsViewModel` | `Features/Friends/FriendsView.swift` | плитка профиля; друзья/входящие/рекомендации + принять/отклонить/удалить |
| Настройки | — (`Session` из окружения) | `Features/Profile/SettingsView.swift` | плитка профиля/deep link; профиль/уведомления/темы из `APIClient+Preferences` (смена статуса — запись `updateStatus`), версия, «Очистить кэш изображений» (чистит `URLCache`) |
| Вход | `Session` | `Features/Profile/ProfileView.swift` (`LoginView`) | состояние «Профиля» для гостя: логин/пароль → Keychain |
| QR-вход | `QrLoginViewModel`, `QrAuthService` | `Features/Auth/QrLoginView.swift` | `sheet` по кнопке «Войти по QR-коду» на экране входа; `auth/qr/create|status` (поллинг), по подтверждению — `Session.adopt(token:profileId:)` |

Особенности: у `PlayerView`, `SettingsView`, `OnboardingView`, `LoginView` нет ViewModel —
нет собственного сетевого состояния. Модальные: плеер — `fullScreenCover` из релиза;
комментарии — `sheet` кнопкой «Все»; библиотека профиля (история, избранное, уведомления,
друзья, настройки) — один `sheet` на плитках; фильтр поиска и deep link — тоже `sheet`.

## 4. Навигация и deep links

`RootView` (`App/AnixartApp.swift`) показывает онбординг или `TabView` с 5 табами:
**Главная**, **Поиск**, **Коллекции**, **Статьи**, **Профиль**. Внутри табов —
`NavigationStack` и `NavigationLink` (релиз из любой карточки, коллекция, чужой профиль,
статья).

Deep links: `App/DeepLinkRouter.swift`.

* Схема `anixart://` и universal links на `anixart-app.com` / `anixart.link`; пути одинаковые:
  `release/{id}`, `profile/{id}`, `collection/{id}`, `search?q=...`, `history`, `favorites`,
  `settings`. Разбор строгий: чужая схема, неизвестный путь, нечисловой/нулевой `id`,
  пустой `q` → `nil`, навигация не меняется. Обработчики — `onOpenURL` (кастомная схема) и
  `onContinueUserActivity` (universal links). **Universal links не работают:** entitlement
  `Associated Domains` в `project.yml` не настроен, iOS просто не отдаёт такие ссылки.
* `NavigationCoordinator` копит `[AppRoute]`; `RootView` показывает верхний маршрут модальным
  `sheet` с кнопкой «Закрыть» (`DeepLinkDestination.swift` переводит маршрут в экран).
  Пока идёт онбординг, маршрут ждёт в очереди и открывается после него. Права не
  проверяются: `history`/`favorites`/`settings` открываются и гостю — экраны сами
  показывают «нужно войти».* Отладочный запуск сразу на экране: `-anixart-open-route=release/1` — `RootView` читает
  аргумент `ProcessInfo.processInfo.arguments` и открывает маршрут после `bootstrap()`.
  Это использует CI скриншотов (тап по симулятору недоступен).

## 5. Авторизация

### 5.1 Поток входа

```
LoginView (ProfileView.swift) → Task { session.signIn(login:password:) }
  → Session.signIn → APIClient.signIn:
      POST auth/signIn, form-urlencoded login=…&password=…
      code 0 → SignInResult(token: profileToken.token, profile:…)
               (пустой токен → .authUnavailable)
      code 2 → .invalidCredentials(...), code 3 → .invalidCredentials(...)
      иначе → .api(code)
  → TokenStore.shared.save(token) → Keychain; UserDefaults: anixart.profile.id
  → isAuthorized = true; profile = …
  → refreshProfile() → GET profile/{id}
```

Сервер принимает вход **только формой** (`application/x-www-form-urlencoded`): на JSON-тело
отвечает HTTP 200 с пустым телом (проверено 24.11.2026, см. `docs/API.md` §1.2). Поэтому
`signIn` собирает строку вручную и кодирует значения через `formEncode`.

### 5.2 Токен и профиль

* Токен берётся из ответа `profileToken.token` (`AuthResponse` в `Models.swift`).
* Хранение — Keychain: `Core/TokenStore.swift`, `kSecClassGenericPassword`,
  `kSecAttrService = com.swiftsoft.anixart.ios`, `kSecAttrAccount = auth-token`,
  доступность `kSecAttrAccessibleAfterFirstUnlock`. В `UserDefaults` токен **не** пишется.
* Идентификатор профиля — `UserDefaults`, ключ `anixart.profile.id` (`Session.profileId`):
  `profile/info` не отдаёт `id`, а `profile/{id}` требует его в пути. При выходе удаляется.
* Подстановка токена — query-параметром: в `APIClient.request` при непустом
  `TokenStore.shared.token` в `URLComponents` добавляется `token` (заголовки
  `token`/`Authorization` сервер игнорирует). Без токена защищённые эндпоинты отвечают
  HTTP 200 и `{"code":401}`.

### 5.3 Состояние сессии

`Session` — единственный глобальный объект аккаунта (`@StateObject` в `AnixartApp`,
`@EnvironmentObject` во вьюхах): `profile`, `isAuthorized`, `isLoading`, `errorMessage`.
`isAuthorized` инициализируется наличием токена; `bootstrap()` вызывает `RootView.task`.
Если `refreshProfile()` получает `.unauthorized`, сессия молча выполняет `signOut()`.
Выход доступен из `ProfileContent` и `SettingsView`. QR-вход подключён: `LoginView` →
`QrLoginView.onToken` → `Session.adopt(token:profileId:)` (токен в Keychain + `refreshProfile`).
Не подключено: восстановление пароля, обновление токена.

## 6. Обработка ошибок

### 6.1 `APIError`

`APIError: LocalizedError, Equatable` объявлен в `Core/APIClient.swift`; `errorDescription`
даёт русский текст для UI.

| Case | Когда возникает | `errorDescription` |
|---|---|---|
| `.badURL` | не собрался `URL`/`URLComponents`, не закодировалась форма | «Некорректный адрес запроса» |
| `.unauthorized` | HTTP 401 или `code == 401` в теле | «Нужен вход в аккаунт Anixart» |
| `.http(Int)` | HTTP-статус вне 2xx/401 | «Сервер ответил ошибкой HTTP N» |
| `.api(Int)` | `code` в теле — не 0/401 | «Сервер вернул код N» |
| `.empty` | пустое тело; `episodeTarget` без `episode` | «Сервер вернул пустой ответ» |
| `.authUnavailable` | `code == 0`, но `profileToken.token` пуст | «Сервер не вернул токен авторизации» |
| `.invalidCredentials(String)` | `signIn`: `code` 2 или 3 | текст, переданный при создании |
| `.decoding(String)` | ответ не разобрался под ожидаемый тип | «Не удалось разобрать ответ сервера» |
| `.transport(String)` | `URLSession.data(for:)` бросил, ответ не HTTP | «Нет связи с сервером: …» |

### 6.2 Конвейер `request` и серверные коды

Порядок в `APIClient.request<T>(_:method:body:contentType:)`:

1. собрать URL (иначе `.badURL`);
2. добавить `?token=`, если токен есть;
3. `perform(URLRequest)`: `URLSession.data(for:)` — ошибка → `.transport`;
   не `HTTPURLResponse` → `.transport`; 401 → `.unauthorized`; статус вне 2xx →
   `.http(status)`;
4. **повторы:** для `GET` вызов обёрнут в `Retry.run(RetryPolicy.default, isRetryable:
   Retry.isRetryable)` — до 3 попыток, паузы 0.4 с × 2 (+20 % jitter), повторяются
   `.transport`, `.http(5xx)` и `.http(429)`; не-GET не повторяется, чтобы не задвоить
   действие;
5. пустые `Data` → `.empty`;
6. `decoder.decode(T.self, …)`; при провале — попытка декодировать `ServerCode`:
   `code == 401` → `.unauthorized`, иной не 0 → `.api(code)`, иначе `.decoding`.

Дальше каждый эндпоинт-метод вызывает `check(code)`:

| Код сервера | Что значит | Что бросает `check` |
|---|---|---|
| `0` | успех | ничего |
| `401` | нет/истёк токен | `.unauthorized` |
| прочие (`2`, `3`, …) | ошибка конкретного метода; у действий 0/2/3 — успех (`success:`) | `.api(code)` |
| `2` (в `auth/signIn`) | логин не существует/не проходит валидацию | `.invalidCredentials(...)` |
| `3` (в `auth/signIn`) | логин существует, пароль неверен | `.invalidCredentials(...)` |

`Paged<Item>` терпим к неполным ответам: `code` по умолчанию 0, `content` — `[]`.

### 6.3 Куда попадает ошибка

Шаблон: `catch` → `errorMessage = error.localizedDescription`; вью рисует `ErrorStateView`
или inline «Повторить». Спецслучаи: `Session.refreshProfile` при 401 молча выходит из
аккаунта; `ReleaseView` на ошибки действий показывает `alert("Ошибка")`; `HomeViewModel`
прячет ошибку, если полки уже загружены, и показывает `OfflineDataBadge` при офлайн-снимке.
Единого глобального презентера ошибок нет, `APIError` в UI не различается — показывается
только текст; `RetryPolicy` подключён только к транспорту `APIClient`.

## 7. Плееры и медиа

### 7.1 Конвейер серии

```
ReleaseView.play(episode)
  → APIClient.episodeTarget(releaseId, sourceId, position)   // подписанная ссылка
  → PlaybackResolver.resolve(episode:sourceName:title:)
       provider = VideoProvider.detect(sourceName:url)
       kodik/libria → web: прокси https://anixmirai.com/iframe?url=<encoded>
       sibnet      → web: страница shell.php + Referer anixart-app.com
       прямой m3u8/mp4 (iframe == false) → .hls
       youtube.com/youtu.be → .youtube(videoId)
       иначе → web с Referer anixart-app.com
  → PlaybackRequest → fullScreenCover(PlayerView)
```

`PlaybackTarget` (`Features/Player/PlaybackTarget.swift`) — `kind` (`.web`, `.hls`,
`.youtube`), `title`, `providerName`, `referer`; `PlaybackError` — тексты для UI.
`PlayerView`: `.hls` → `NativePlayerView` (AVPlayer, `AVPlayerLayer`); `.web` →
`PlayerWebView` (WKWebView с Referer/iframe-обёрткой), но сначала пробует нативный резолвер
для Sibnet/AniLibria/RuTube/AnixPlayer и при удаче играет HLS в `NativePlayerView`; таймаут
20 с на загрузку → экран ошибки с кнопкой «Открыть в Safari»; кнопка закрытия, меню качества
(если HLS отдал >1 варианта), кнопка PiP (если доступен).

### 7.2 Нативный резолверы (`Features/Player/`)

| Резолвер | Что делает |
|---|---|
| `SibnetResolver` | `shell.php` с мобильным UA → regex `src: "…"` → резолв 302 с `Referer: shell.php` → MP4/HLS; при 403 повтор с Android-UA (UA из `config/toggles` не подключён — фолбэк) |
| `AniLibriaResolver` | `id`/`ep` из signed `iframe.php` → `https://anilibria.top/api/v1/anime/releases/{id}` → `episodes[ordinal == ep]` → `hls_1080/720/480`; фолбэк — разбор Playerjs из signed страницы |
| `RutubeResolver` | 32-hex id из 4 шаблонов ссылок → `rutube.ru/api/play/options/{id}/?no_404=true&referer&pver=v2` с `Referer: https://rutube.ru/` → `video_balancer.m3u8`; `blocking_rule` → понятная ошибка региона |
| `AnixPlayerResolver` | `ani`/`ep` из ссылки → `api.studiomir.club/api?ani=…&apikey=…` → `players.tsm[]` (TV → TR → последняя) → `hls[2160p/1080p/720p]` или `url` |

`NativePlayerView` (~590 строк): `AVPlayerLayer`, тап play/pause, спиннер буферизации и
`playbackStalled`, авто-seek на сохранённую позицию, аудиосессия `.playback`/
`.moviePlayback` (+ `UIBackgroundModes: audio` для фона), обработка прерываний звука,
прогресс раз в 5 с, по концу — `markWatched` + `history/add`, отдаёт слой наружу для
`PiPController` (PiP); `AirPlayButton` написан, но в интерфейс не вставлен.
`VideoQualitySelector` разбирает master-плейлист HLS (меню в toolbar, выбор в `UserDefaults`,
`anixart.video.quality`); для Kodik в рабочем дереве добавлено меню качества с пересборкой
подписанной ссылки.

«Следующая серия»: `NextEpisodeService` (кэш списка серий 10 минут, свежий `episode/target`
по нажатию) подключён к `PlayerView` — по `onFinished` `NativePlayerView` ищет следующую
серию и показывает кнопку «Следующая: …»; `typeId` передаётся из `ReleaseViewModel`.
Для web-плееров кнопки нет (они не сообщают о конце), YouTube-переход не поддерживается.

## 8. Кэши, ретраи и прогресс

| Слой | Где | Что хранит и как используется |
|---|---|---|
| `ImageCache` (actor) | `Core/ImageCache.swift` | память до 30 МБ + диск `Caches/anixart-images`, объединение одновременных загрузок, лимит загрузки 8 МБ. **Подключён:** `Components.RemoteImage` грузит через `ImageCache.shared.imageData(for:)`. `CachedAsyncImage` — готовая вью на этом кэше — не вызывается. «Очистить кэш изображений» в настройках чистит `URLCache`, а **не** `ImageCache` (расхождение). |
| `OfflineCache` (actor) + `OfflineIntegration` | `Core/OfflineCache.swift`, `OfflineIntegration.swift` | JSON в `Caches/anixart-offline/<key>.json` с датой; ключи `catalog-{page}`, `history-{page}`, `release-{id}`, `profile-{id}`. TTL: каталог 30 мин, история 10 мин, карточка релиза 24 ч. **Подключено:** главная кэширует/читает каталог (бейдж «Офлайн-данные»), история — первую страницу; `storeRelease` копится, но экран релиза кэш не читает; `profile` — не используется; `OfflineCache.clear()/diskSize()` — не вызываются. |
| `RetryPolicy`/`Retry` | `Core/RetryPolicy.swift` | 3 попытки, экспоненциальная пауза, jitter; `isRetryable` для `APIError.transport`, 5xx, 429. **Подключён:** `APIClient.request` оборачивает только `GET`; POST/форма не повторяются. Покрыт тестами (18 в `InfrastructureTests`). |
| `PlaybackProgress` (`@MainActor` сервис) | `Features/Player/PlaybackProgress.swift` | до 50 позиций `releaseId-sourceId-position` в `UserDefaults` (`anixart.playback.*`), `episode/watch` + `history/add` при наличии токена; `continueWatching()` (10 последних) используется полкой на главной; `lastError` никто не читает. |
| `NextEpisodeService` (`@MainActor` сервис) | `Features/Player/NextEpisodeService.swift` | кэш списков серий: 10 минут, 8 записей; подключён к плееру (кнопка «Следующая»), `lastError` не показывается. |
| `VideoQualitySelector` / `OfflineDataBadge` | `Features/Player/VideoQuality.swift`, `Core/OfflineIntegration.swift` | выбор качества в `UserDefaults` (`anixart.video.quality`); бейдж «Офлайн-данные» на главной/истории. |

## 9. Инструменты проверки

| Инструмент | Что проверяет | Как запускается |
|---|---|---|
| `ios/tools/api_probe.py` | живой контракт API: 13 проверок наличия/типов полей, которые ждут модели; защищённые эндпоинты отвечают 401 | `python3 ios/tools/api_probe.py` |
| `ios/tools/ModelCheck/main.swift` | декодирование моделей на этих фикстурах (9 сценариев) | `swiftc -o modelcheck Models.swift ModelCheck/main.swift && ./modelcheck tools/fixtures` |
| `ios/tools/StubSwiftUI/check.py` + `StubKit.swift` | typecheck 51 из 53 файлов приложения с фальшивыми SwiftUI/Combine/WebKit/AVKit/Security через Compiler Explorer; `PlayerView.swift`/`NativePlayerView.swift` в `SKIP_STUBS` (AVFoundation/PiP не смоделированы) | `python3 ios/tools/StubSwiftUI/check.py [stub\|mutate]` |
| `ios/tools/core_check.sh`, `check.sh` | typecheck `Models.swift`, `RetryPolicy.swift`, `APIClient.swift` (заглушка `TokenStore`) + ModelCheck; полная сборка на macOS (xcodegen → api_probe → xcodebuild, без тестов) | `./tools/core_check.sh`, `./tools/check.sh [device]` |
| `ios/AnixartTests/*.swift`, `ios/AnixartUITests/*.swift` | XCTest: 57 юнит-тестов (модели 12, API 12, инфраструктура 18, плеер 7, резолверы 8) + 4 UI-смоук-теста (схема `AnixartUI`) | ⌘U / `xcodebuild test -scheme Anixart` / `-scheme AnixartUI` |
| `.github/workflows/*.yml` | CI: `build.yml` (job `core` — `ubuntu-22.04`, Swift 6.0, typecheck + ModelCheck; job `ios` — `macos-15`, xcodegen/build/тесты; `ipa` — вручную), `release.yml` (`.ipa` → GitHub Release по тегу `v*`), `screenshots.yml` (7 скриншотов в `ui-screenshots`) | push/PR/тег/вручную |

Подробности по уровням — `docs/TESTING.md`; сборка и установка — `docs/RELEASE.md`,
контракт API — `docs/API.md`.

## 10. Правила добавления нового экрана

1. **Модель.** В `Models/Models.swift` — `XResponse: Decodable { let code: Int; let x: X? }`;
   поля — `CodingKeys` с snake_case, почти все опциональные; производные для UI — там же.
2. **Эндпоинт.** В `Core/APIClient.swift` или `Core/APIClient+*.swift` — метод рядом с
   похожими: `func x(id: Int, page: Int = 1) async throws -> X`; внутри `request(...)`,
   `try check(value.code)`, `guard let` при вложенном объекте. Никакой логики UI.
3. **Контракт.** Проверка в `api_probe.py` (метод, путь, поля, типы), при необходимости —
   фикстура в `fetch_fixtures.py` и `expect(...)` в `ModelCheck`.
4. **ViewModel.** `@MainActor final class XViewModel: ObservableObject`, `@Published
   private(set)` данных, `isLoading`, `errorMessage`, `private let api = APIClient.shared`,
   `load()` с `defer` и `catch`. Образец списка — `HistoryViewModel`/`FavoritesViewModel`
   (`currentPage`, `totalPages`, `canLoadMore`, дедупликация по `id`).
5. **View.** `struct XView: View` с `@StateObject`; для таба — свой `NavigationStack`, для
   вложенного — без него. Обязательно `.screenBackground()`, `.task { await model.load() }`,
   `.refreshable` для списков, состояния «загрузка → ошибка → пусто → данные» через
   `LoadingView`/`ErrorStateView`, скелетоны для первых загрузок.
6. **Навигация.** Вкладка — в `RootView.tabs`; переход — `NavigationLink`; модальный —
   `.sheet`/`.fullScreenCover`. Для deep link — кейс в `AppRoute` и ветка в
   `DeepLinkDestination.swift`. Нужен аккаунт — `@EnvironmentObject var session: Session`.
7. **Проверка и документация.** `StubSwiftUI/check.py`, `api_probe.py`, на macOS —
   `./tools/check.sh` и `xcodebuild test`. Обновите §3, `ios/README.md`, `ios/ROADMAP.md`.

Чек-лист: нет внешних зависимостей; во вьюхах нет `URLSession`/`UserDefaults`; ошибки —
текстом через `errorMessage`; строки на русском; цвета/радиусы из `Theme`; пароль/токен не
попадают в `UserDefaults` и логи; сетевой вызов отменяем или завершается без гонок.

## 11. Технический долг и непроверенное

### 11.1 Не подключено к навигации/UI (на момент снимка)

* **`CachedAsyncImage`** написана, но не используется (сам `ImageCache` уже работает через
  `RemoteImage`); **`AirPlayButton`** написан, в интерфейс не вставлен.
* **`OfflineCache.clear()`/`diskSize()`, `ImageCache.clear()`** — не вызываются; «Очистить
  кэш изображений» чистит только `URLCache`.
* **`notification/delete/all`** (`APIClient.deleteAll`) — метод есть, кнопки «удалить все» нет.
* **Universal links** обрабатываются кодом, но entitlement `Associated Domains` не настроен;
  `OfflineIntegration.storeRelease` копит карточки релизов, но экран релиза их не читает.

### 11.2 Не проверено

* **Устройство.** Четыре нативных резолвера и настройка плеера проверены только живыми
  запросами парсеров (python), Swift-пути `AVPlayer`/`WKWebView` — нет; PiP, фон, поворот и
  прогресс на устройстве не проверялись. Kodik идёт через прокси `anixmirai.com` (может
  отвалиться), Sibnet с нашей сети отдаёт 403, живых источников AnixPlayer не нашлось,
  RuTube требует RU-IP (`docs/PLAYERS.md` §12).
* **Действия с токеном.** Список/избранное/оценка на релизе подключены, но живьём не
  вызывались: успешные ответы `profile/list/*`, `favorite/*`, `release/vote/*`, заявок в
  друзья, `episode/watch`, `history/add` известны только по контракту dex.
* **Вход.** Успешный `auth/signIn` по журналу проверялся на `<test-login>` (ROADMAP), в этой
  сборке на устройстве не перепроверялся; успешный QR-статус (status=2) не проверен.
* **Xcode SDK.** Сборка `xcodebuild` — единственный способ проверить доступность API iOS 16,
  SwiftUI-модификаторы, AssetCatalog, `Info.plist`, Privacy Manifest и подпись; локальной
  Xcode-сборки не было (Windows), работает только CI (последний зелёный прогон зафиксирован
  при 24 тестах, сейчас их 57).
* **Актор-изоляция.** `SWIFT_STRICT_CONCURRENCY: minimal` скрывает нарушения `Sendable`;
  заглушка `View` помечена `@MainActor` (как в iOS 18 SDK), в Xcode 15 `View` не изолирован —
  выводы «мягкой» проверки могут отличаться.

### 11.3 Риски и дефекты дизайна

* **Изменяемое состояние без изоляции.** `TokenStore.shared` читается из `APIClient.request`
  в конкурентных задачах; `APIClient.shared` не `Sendable`, общие `JSONDecoder`/`JSONEncoder`
  не потокобезопасны, а четыре экрана запускают по два запроса параллельно (`async let`) и
  декодируют одновременно. Спасает `minimal`-строгость.
* **`APIClient` — синглтон без протокола:** ViewModel нельзя протестировать с подменой сети
  (в тестах подменяется `URLProtocol`, но не `APIClient`); тестов на VM нет.
* **Молчаливые ошибки.** `PlaybackProgress.lastError` и `NextEpisodeService.lastError` не
  читает никто; `HomeViewModel` при загруженных полках и `ReleaseViewModel` после загрузки
  релиза прячут ошибку; общий алерт ошибок есть только в `ReleaseView`. Модели почти целиком
  опциональные: пропавшее поле не ломает приложение, но и не логируется.
* **Плеер:** ссылка подписана по IP/времени; реклама Kodik и `config/toggles` не
  реализованы; ни качества (кроме Kodik, в работе), ни PiP, ни «следующей серии» на
  web-плеерах нет.
* **Безопасность:** `NSAllowsArbitraryLoads: true`; токен идёт в query-строке (следы в логах
  и истории прокси); нет certificate pinning; camera/photo usage объявлены без смены
  аватара. Privacy Manifest есть, но не проверен в сборке.
* **Гигиена.** `ios/README.md` и `ios/ROADMAP.md` написаны до последней волны правок (кэш
  картинок, ретраи, «Продолжить просмотр», «Следующая серия», QR-вход, Privacy Manifest) и
  в этих местах отстают от кода; в `LoginView` остались неиспользуемый `handleQrToken` и
  невключаемая памятка после QR; линтера в CI нет.

## 12. Карта файлов

```
anixart/
├── .github/workflows/    build.yml (core + ios + ipa), release.yml (тег v*), screenshots.yml
├── analysis/             разбор APK: endpoints.txt (319 путей), strings.txt, fixtures, dex
├── docs/                 ARCHITECTURE.md, API.md, TESTING.md, RELEASE.md, PLAYERS.md и др.
└── ios/
    ├── README.md / PORTING.md / ROADMAP.md   сборка / разбор APK / паритет функций
    ├── project.yml       XcodeGen: iOS 16, Swift 5.9, тёмная тема, ATS, UIBackgroundModes,
    │                     CFBundleURLTypes, схемы Anixart (unit-тесты) и AnixartUI (UI-тесты)
    ├── Anixart/          53 Swift-файла
    │   ├── App/          AnixartApp (RootView, 5 табов), Session, Theme, DeepLink*
    │   ├── Core/         APIClient + APIClient+{Actions,Articles,Feed,Friends,Notifications,
    │   │                 Preferences}, TokenStore, RetryPolicy, OfflineCache/Integration,
    │   │                 ImageCache
    │   ├── Models/Models.swift        все Codable-модели и обёртки ответов
    │   ├── Components/   Components.swift (RemoteImage, постеры, полки, состояния),
    │   │                 SkeletonViews.swift
    │   ├── Features/     Home (+Banner, ContinueWatching), Search (+Filters/Collections/
    │   │                 Profiles), Collections (+Detail), Articles (+Detail), Release,
    │   │                 Player (PlayerView, PlayerWebView, NativePlayerView,
    │   │                 PlaybackResolver/Target, 4 резолвера, VideoQuality,
    │   │                 PlaybackProgress, NextEpisodeService), Comments, History,
    │   │                 Favorites, Profile (+UserProfile, Settings), Notifications,
    │   │                 Friends, Auth (QR), Onboarding
    │   └── Resources/    Assets.xcassets (иконка, AccentColor), PrivacyInfo.xcprivacy;
    │                     Info.plist генерируется XcodeGen из project.yml
    ├── AnixartTests/     5 файлов, 57 юнит-тестов (ModelsDecoding, APIClient, Infrastructure,
    │                     Playback, ProviderResolver)
    ├── AnixartUITests/   SmokeUITests.swift — 4 UI-теста (схема AnixartUI)
    └── tools/            api_probe.py (13), fetch_fixtures.py (9), ModelCheck (9),
                          StubSwiftUI/ (51 из 53), core_check.sh, check.sh, make_app_icon.py,
                          fixtures/
```
