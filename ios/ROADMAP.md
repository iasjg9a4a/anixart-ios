# Anixart iOS — дорожная карта

Обновлено 24.11.2026 по коду на коммит 60f05d5. Основано на сверке
Android-приложения (APK 11 beta 3), `analysis/endpoints.txt` (319 путей), живых запросах
(24.11.2026) и документах [docs/API.md](../docs/API.md), [docs/PLAYERS.md](../docs/PLAYERS.md),
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md). Сборка и установка — [README.md](README.md),
разбор APK — [PORTING.md](PORTING.md).

## Где мы сейчас

| Этап | Статус |
|---|---|
| 0. Инвентаризация функций | ✅ таблица паритета ниже |
| 1. Реверс API | ✅ 319 путей в dex; 54 шаблона в клиенте: 42 в `APIClient` + расширения, 6 действий (`APIClient+Actions`), 3 заявки в друзья, 3 запроса QR; **авторизация разгадана** (form-urlencoded + `?token=`) |
| 2. Дизайн-система | ✅ палитра, компоненты, тёмная тема, иконка, скелетоны загрузки |
| 3. Архитектура | ✅ MVVM + один `APIClient`, без внешних зависимостей; см. `docs/ARCHITECTURE.md` |
| 4. Экраны | 🟢 17 подключённых (5 табов + 11 + онбординг); статьи, уведомления, друзья — полноценные экраны; в поиске каталог с фильтром, на релизе — действия со списком/избранным/оценкой |
| 5. Плееры и медиа | 🟡 6 провайдеров + нативный AVPlayer: качество (нативное и Kodik), PiP, фон, прогресс/докат, «следующая серия»; **на устройстве не проверено**; нет рекламы Kodik и `config/toggles` |
| 6. Инфраструктура | 🟡 `ImageCache` и `RetryPolicy` реализованы и покрыты тестами, но к UI/`APIClient` не подключены; `OfflineCache` — только каталог и история; deep links (кастомная схема); 57 тестов; нет пушей, аналитики, крашлогов |
| 7. Релиз | 🟡 неподписанный `.ipa` собирается в CI (build/release) + скриншоты; Privacy Manifest нет; App Store закрыт (правило 5.2) |

## Экраны

Главная (5 полок + баннеры + догрузка каталога) · Поиск (каталог с фильтром +
релизы / коллекции / люди) · Коллекции (хаб + каталог) · Коллекция (шапка, счётчики, релизы) ·
Страница релиза (метаданные, жанры, описание, комментарии, действия: список / избранное /
оценка / поделиться; озвучки → источники → серии, связанные) · Плеер · Комментарии ·
История · Избранное · Профиль (вход внутри; 5 списков; бейдж уведомлений) · Чужой профиль ·
Настройки · Статьи (лента) · Статья (блоки + комментарии) · Уведомления · Друзья · Онбординг.

Написан, но **не подключён к навигации**: QR-вход (`Auth/QrLoginView.swift`, клиент
`auth/qr/*` и поллинг готовы).

## Паритет функций

| Функция | iOS | Эндпоинты | Осталось |
|---|---|---|---|
| Главная | 🟢 полки «смотрят/обсуждают/рекомендуем», коллекции, баннеры, догрузка каталога, офлайн-снимок | `discover/hub`, `filter/{page}` | отдельный экран «Сейчас смотрят», рекомендации под токеном (`discover/recommendations/{page}`) |
| Поиск | 🟢 пустой запрос — каталог с фильтром (сортировка, жанры, год) + чипы; текст — 3 сегмента, коллекции и люди с догрузкой | `filter/{page}`, `POST search/releases/{page}`, `POST search/collections/{page}`, `POST search/profiles/{page}` | пагинация выдачи релизов, сортировка результатов поиска, поиск по истории/избранному |
| Страница релиза | 🟢 метаданные, жанры, описание, комментарии, озвучки → источники → серии; действия: список (5 статусов), избранное, оценка 1–5, «поделиться» | `release/{id}`, `episode/{r}`, `episode/{r}/{typeId}`, `episode/{r}/{typeId}/{sourceId}`, `episode/target/...`, `profile/list/add/{status}/{id}`, `profile/list/delete/{status}/{id}`, `favorite/add/{id}`, `favorite/delete/{id}`, `release/vote/add/{id}/{vote}` | скриншоты релиза, постраничные «похожие» (`related/{relatedId}/{page}`), проверка действий с токеном |
| **Плееры** | 🟡 Kodik (web через `anixmirai`-прокси), AniLibria/Libria/Liberty, Sibnet, RuTube, AnixPlayer/StudioMir (нативные резолверы), YouTube (iframe); AVPlayer + качество + PiP + фон + прогресс | `episode/target/{r}/{s}/{pos}`, `episode/watch/{r}/{s}/{pos}`, `history/add/{r}/{s}/{pos}` | проверка на устройстве ([docs/PLAYERS.md §12](../docs/PLAYERS.md#12-что-проверить-на-устройстве)), «следующая серия» в UI (`NextEpisodeService` не подключён), реклама Kodik, `config/toggles`, AirPlay-кнопка, качество на web-плеерах, PiP для web |
| Комментарии | 🟡 чтение + пагинация | `release/comment/all/{id}/{page}` | отправка, ответы, голоса (нужен вход) |
| Коллекции | 🟢 хаб, каталог, детали, пагинация релизов | `collection/hub`, `collection/all/{page}`, `collection/{id}`, `collection/{id}/releases/{page}` | создание/редактирование, свои и избранные коллекции |
| Статьи | 🟢 лента с пагинацией + читалка с блоками + комментарии (чтение) | `search/feed/{page}`, `article/{id}`, `article/comment/all/{id}/{page}` | голоса/репосты, поиск по статьям, ответы на комментарии |
| Уведомления | 🟢 список, счётчик (бейдж на плитке профиля), «прочитать все», удаление по одному | `notification/all/{page}`, `notification/count`, `notification/read`, `notification/{type}/delete/{id}` | кнопка «удалить все» (`notification/delete/all` в API готов), проверка на непустом аккаунте (у тестового 0), переходы по типам |
| Друзья | 🟢 друзья, входящие заявки, рекомендации; принять/отклонить/удалить | `profile/friend/all/{id}/{page}`, `profile/friend/requests/in/{page}`, `profile/friend/recommendations`, `profile/friend/request/send/{id}`, `.../remove/{id}`, `.../hide/{id}` | проверка на непустом аккаунте, «добавить в друзья» из чужого профиля |
| Профиль | 🟢 свой и чужой, счётчики, списки по статусам | `profile/{id}`, `profile/list/all/{status}/{page}` | редактирование профиля, аватар, значки |
| Списки | 🟢 чтение + добавление/удаление со страницы релиза | `profile/list/all/{status}/{page}`, `profile/list/add/{status}/{id}`, `profile/list/delete/{status}/{id}` | удаление из самого списка, drag-and-drop порядка |
| История | 🟢 + офлайн-снимок | `history/{page}` | удаление записи: `history/delete/{r_id}` готов в API, UI нет |
| Избранное | 🟢 чтение + пагинация + переключатель на релизе | `favorite/all/{page}`, `favorite/add/{id}`, `favorite/delete/{id}` | удаление из самого списка, проверка с живым аккаунтом |
| Настройки | 🟡 локальные: аккаунт, тема (только тёмная), версия, очистка `URLCache` | — | UI настроек аккаунта на `profile/preference/my` (API готов), Privacy Manifest |
| Вход | 🟢 логин/пароль + Keychain + `?token=` (по журналу проверен на `<test-login>`) | `auth/signIn` (form-urlencoded) | подключить QR-вход, повторная проверка на устройстве |
| «Продолжить просмотр» | 🟡 `PlaybackProgress` пишет позиции и `continueWatching()` отдаёт список | — | экрана/полки на главной нет |
| Скачивание | 🟡 HLS (AniLibria/RuTube/AnixPlayer) через `AVAssetDownloadURLSession`, экран «Загрузки»; Kodik/Sibnet нельзя | `episode/target/...` | проверка скачивания/офлайна на устройстве |

## Ближайшие шаги

1. **Проверка на устройстве (macOS + iPhone).** Плееры по списку
   [docs/PLAYERS.md §12](../docs/PLAYERS.md#12-что-проверить-на-устройстве): Kodik через
   прокси, Sibnet (403 с нашей сети), Libria (гео CDN), RuTube (регион-лок), AnixPlayer,
   YouTube; плюс PiP, фон, поворот, поведение в Safari. Прогон CI после расширения кода и
   тестов (49 → 57) тоже может вскрыть ошибки Xcode SDK.
2. **Плеер в UI:** подключить `NextEpisodeService` к `PlayerView` (кнопка «Следующая
   серия», передать `typeId` из `ReleaseViewModel.selectedTypeId`), вставить `AirPlayButton`
   в панель управления; решить, нужна ли кнопка «следующая» и для web-плееров (сейчас —
   только нативные HLS).
3. **Проверить действия с живым токеном:** список / избранное / оценка на релизе уже
   подключены, но успешные ответы `profile/list/*`, `favorite/*`, `release/vote/*` известны
   только по контракту dex. Затем — удаление из истории (`history/delete`), полка
   «Продолжить просмотр» на `continueWatching()`, удаление из самих списков.
4. **Подключить написанное:** QR-вход в экран входа, `APIClient+Preferences` — в настройки,
   `CachedAsyncImage` — вместо `AsyncImage` в `RemoteImage` (и очистку `ImageCache`, а не
   только `URLCache`), `RetryPolicy` — в `APIClient`.
5. **Качество на web-плеерах.** Для Kodik качество задаёт их страница; нужен либо JS-мост
   в WKWebView (управление `player.js`), либо нативный путь Kodik (парсер в dex
   обфусцирован — не разгадан, см. [docs/PLAYERS.md](../docs/PLAYERS.md) §11).
6. **Офлайн-загрузки серий** — только после разбора подписанных ссылок (`d`/`s`/`ip`
   обновляются каждый час); до этого офлайн-режим остаётся на каталоге и истории.
7. **Пуши и аналитика** — APNs требует платного аккаунта и сертификата; крашлоги/аналитика
   не подключены (в API есть `analytics/startup`, `api/crash/upload`, но это путь клиента
   оригинала, не наш).
8. **CI и релиз:** подтвердить зелёный прогон `build.yml` уже с 57 тестами (последний
   зафиксированный — при 24 тестах), прогнать `screenshots.yml`; дальше — Privacy Manifest
   и `NSExceptionDomains` вместо `NSAllowsArbitraryLoads`.
9. **App Store — не начинать.** Стриминг без прав = отказ по 5.2; из легального только
   TestFlight (платный аккаунт) и личная сборка/AltStore/Sideloadly — см.
   [docs/RELEASE.md](../docs/RELEASE.md#6-app-store-почему-нельзя).

## Что нельзя без входа

`profile/info`, `profile/list/all/...`, `profile/list/add|delete`, `profile/preference/*`,
`history/*`, `favorite/all`, `favorite/add|delete`, `collectionFavorite/*`, `notification/*`,
`feed/latest`, `feed/all`, `episode/watch|unwatch`, `episode/watched`,
`history/add|delete`, `release/comment/add`, `release/vote/*`,
`profile/friend/request/*` — все write-методы.
Без токена сервер отвечает `200` + `{"code":401}`. **Проверено:** вход работает (аккаунт
`<test-login>`), токен уходит query-параметром; в этой итерации на устройстве не перепроверялся.

## Риски

* **App Store** — правило 5.2; легальные варианты: только каталог/трекер.
* **Подписанные ссылки** — `episode/target/...` привязана к IP и времени (Kodik `d`/`s`/`ip`,
  Libria `clientIp`/`countryIso`); кэшировать нельзя.
* **Сторонний прокси** `anixmirai.com` — единственный путь для Kodik; отвалится — Kodik
  перестанет играть (нативный парсер Kodik не разгадан).
* **Нестабильность бэкенда** — контракт проверяется `tools/api_probe.py`; форма живых
  элементов уведомлений и друзей не подтверждена (0 записей у тестового аккаунта).
* **Непроверенный код на устройстве** — все резолверы плееров проверены только живыми
  запросами парсеров (python), Swift-пути AVPlayer/WKWebView/PiP — нет; Xcode-сборка
  проверяется только CI.
* **Не подключённые слои** создают ложное впечатление готовности: `RetryPolicy`, `ImageCache`,
  `Preferences`, `NextEpisodeService`, `continueWatching`, `AirPlayButton`, `QrLoginView`
  есть в коде, но пользователь их не видит (или видит не то: кэш картинок не работает,
  «Очистить кэш» чистит только `URLCache`).

## Чем проверено

* `python tools/api_probe.py` — 13 живых проверок контракта (каталог, поиск, релиз, профиль,
  серии, ссылка на плеер, коллекции, комментарии, `401`); см. [docs/API.md](../docs/API.md).
* `./tools/core_check.sh` — typecheck ядра + `ModelCheck` на 9 фикстурах `tools/fixtures/`.
* `python tools/StubSwiftUI/check.py` — typecheck всего кода приложения на заглушках.
* `ios/AnixartTests` — 57 XCTest: модели (12), API-клиент (12), инфраструктура (18),
  плеер (7), резолверы провайдеров (8); таблица в [README.md](README.md#тесты).
* CI: `build.yml` (`core` + `ios` + `ipa`), `release.yml`, `screenshots.yml` — ссылки в
  [README.md](README.md#ci).
* Внешняя сверка: сторонний SDK `anixapi` — расхождения по методам/полям и что из этого
  стоит внедрять, [docs/SDK_CROSSCHECK.md](../docs/SDK_CROSSCHECK.md).
