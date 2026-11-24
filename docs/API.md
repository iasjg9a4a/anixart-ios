# API Anixart: справочник

Справочник по HTTP-API, с которым работает Android-приложение Anixart 11 beta
(`com.swiftsoft.anixartd`) и независимый iOS-клиент из этого репозитория.

Источники: `analysis/endpoints.txt` (319 путей из `classes*.dex`), `ios/Anixart/Core/APIClient.swift`
и расширения `APIClient+Articles/Feed/Friends/Preferences/Notifications`, `ios/Anixart/Models/Models.swift`,
`ios/PORTING.md`, `ios/ROADMAP.md`, `ios/tools/api_probe.py`, фикстуры `ios/tools/fixtures/`
и `analysis/fixtures/`, а также экран `Features/Auth/QrLoginView.swift`. Живые проверки —
24.11.2026, анонимно, без записывающих запросов.

Пометки: ✅ — проверено живым запросом 24.11.2026; 📦 — форма ответа сохранена в фикстуре;
`code` — поле в JSON, а не HTTP-статус. Снимок кода: 24.11.2026.

## 1. Общее

### 1.1 Хост и транспорт

| Параметр | Значение |
|---|---|
| Базовый адрес | `https://api-s.anixsekai.com/` |
| Формат | JSON (UTF-8), заголовок `Accept: application/json` |
| Таймауты iOS-клиента | 25 с на запрос, 40 с на ресурс |
| Методы | GET — чтение; POST — поиск (JSON), авторизация и QR (form-urlencoded), часть списков |
| Другие домены APK | `anixart-app.com`, `editor.anixsekai.com`, `api.studiomir.club` — веб/редактор/реклама, не API |

`episode/target/...` отдаёт ссылку на сторонний плеер (Kodik и т.п.), подписанную по IP
и времени: её надо запрашивать непосредственно перед показом.

### 1.2 Авторизация

Вход по логину и паролю — `POST auth/signIn`, только `application/x-www-form-urlencoded`:

```text
POST https://api-s.anixsekai.com/auth/signIn
Content-Type: application/x-www-form-urlencoded

login=<логин>&password=<пароль>
```

На JSON-тело сервер отвечает HTTP 200 с пустым телом (проверено), поэтому форма обязательна.
Успех — `code: 0` и токен; сохранённый образец ответа — `analysis/login_response_sample.json`:

```json
{"code": 0, "profile": {"id": <profile-id>, "login": "<test-login>", "...": "93 поля"},
 "profileToken": {"id": 2602911, "token": "***"}}
```

Коды `auth/signIn` (HTTP всегда 200):

| code | Значение | Чем проверено |
|---|---|---|
| 0 | успех: `profile` + `profileToken.token` | образец ответа в `analysis/login_response_sample.json`; вход на аккаунте `<test-login>` заявлен проверенным в `ios/ROADMAP.md` и `APIClient+Friends.swift` |
| 2 | логин не подходит: не существует или не проходит валидацию (длина/формат) | 24 случайных логина → 2 (проверенные через `auth/checkLogin` — `available: true`); логины длиной 1–2 и 21 символ → 2 |
| 3 | логин существует, пароль неверен | 20 логинов из фикстур (реальные пользователи) + неверный пароль → 3; `auth/checkLogin` для них `available: false` |

> Расхождение с `ios/PORTING.md`: там 2 описано как «невалидная длина логина», 3 — как
> «неверная пара (анти-энумерация)». Живая проверка 24.11.2026 показала другое: код 2
> получают и валидные по длине, но несуществующие логины; код 3 — существующий логин
> с неверным паролем. То есть сервер различает «логин не найден» и «неверный пароль».

Проверка занятости логина — `POST auth/checkLogin`, форма `login=<...>`:
существующий логин → `{"code":0,"available":false,"suggested_logins":[...]}`,
свободный → `{"code":0,"available":true}` (проверено live).

Токен (`profileToken.token`) клиент передаёт query-параметром `?token=<...>` в каждом
запросе — так делает `APIClient.request`; по README/ROADMAP заголовки `token`/`Authorization`
сервер игнорирует. Без токена защищённые эндпоинты отвечают HTTP 200 и `{"code":401}` (§2.2).

QR-вход (по `Features/Auth/QrLoginView.swift`, живая проба 24.11.2026): все шаги — POST,
тело form-urlencoded.

| Шаг | Тело формы | Ответ |
|---|---|---|
| `auth/qr/create` | `device=iPhone` | `code, key, secret, pin, expires_in, poll_interval` (пример: `expires_in=600`, `poll_interval=3`) |
| `auth/qr/status` | `key`, `secret` | `code` + `status`: 0 — ждём, 1 — код введён, 2 — подтверждён (+ `profileToken`: `token`, `id`); `code` 2 — истёк/неизвестен, 3 — отклонён, 4 — много попыток, 6 — много запросов |
| `auth/qr/open` | `key` + `?token=` | служебное, только с авторизованного устройства |
| `auth/qr/confirm` | `key`, `pin` + `?token=` | подтверждение входа на другом устройстве |
| `auth/qr/decline` | `key` + `?token=` | отклонение; без токена — `{"code":401}` (проверено) |

`create` и `status` работают без авторизации; положительный `status = 2` с `profileToken` из
APK описан, но живым входом не проверен. iOS подключил QR-вход (`LoginView` →
`Session.adopt`), `id` — из `profileToken.id`. Провайдеры (`auth/firebase`/`google`/
`telegram`/`vk`/`yandex`), регистрация (`signUp|verify|resend`), `restore*` — не проверялись.

### 1.3 Пагинация

Списки приходят в конверте Paged:

```json
{"code": 0, "content": [ ... ], "total_count": 150579, "total_page_count": 6023, "current_page": 1}
```

* `content` — массив элементов; размер страницы на проверенных списках — 25.
* Номер страницы передаётся в пути. Нумерация **с нуля**: page=0 — первая страница.
  Проверено: `release/comment/all/1/0` новее, чем `/1/1`; `collection/all/0` и `/1` —
  разные наборы; `collection/1/releases/0` отдаёт 8 элементов, а `/1` — пусто.
  То же независимо подтверждено в `APIClient+Friends.swift`: на профиле 1601520 (464 друга)
  `page=0` и `page=1` дают разные 25 записей без пересечений.
* Метаданные достоверны не везде. `collection/all/{page}`: `total_count=150579`,
  `total_page_count=6023`, `current_page` = запрошенная страница. А `filter/{page}` и
  `search/releases/{page}` на любой странице отдают `total_count` = числу элементов выдачи
  (обычно 25) и `total_page_count=0, current_page=0`; страница при этом работает (разные id
  на page=0/1/2). Пагинировать стоит «пока `content` не пуст», а не по `total_page_count`.
* iOS-клиент по умолчанию шлёт `page: Int = 1` (`APIClient.swift`). Для эндпоинтов
  с нулевой нумерацией это вторая страница — при порте начинать с 0.

### 1.4 Коды ошибок и HTTP-поведение

Ошибка обычно приходит с HTTP 200 и полем `code`; HTTP 401 в ответах не наблюдался:

| code | Значение | Проверено |
|---|---|---|
| 0 | успех | все эндпоинты §2.1 |
| 401 | нужна авторизация / токен отсутствует или невалиден | 46 путей, §2.2 |
| 1 | не подтверждён: `achievement/get`, `collection/all/profile/28`, `video/profile/1`, `article/comment/all/profile/...` | живой ответ |
| 2 | `auth/signIn` — логин не найден; `article/{id}` — статья не найдена (`article/1`, `article/20028` → `{"code":2,"article":null}`) | живой ответ |
| 3 | `auth/signIn` — неверный пароль; `achievement/preview/{code}` — достижение не найдено | живой ответ |
| 4 | `achievement/get` при POST; QR: слишком много попыток — смысл зависит от эндпоинта | живой ответ |

Один и тот же числовой код в разных ресурсах значит разное — сверяться с эндпоинтом.

Неверный метод/путь: `GET` на POST-поиск → HTTP 400; `POST` на GET-эндпоинт
(`collection/hub`, `release/{id}`, `episode/{releaseId}`, `type/all`) → HTTP 405;
несуществующий путь → 404. Пустое тело при HTTP 200 (`config/toggles`, `config/urls` и др.)
— валидный ответ сервера; iOS-клиент трактует его как `APIError.empty`. Список таких
путей — §2.3.

## 2. Проверенные эндпоинты

Методика: `python ios/tools/api_probe.py` — 13 проверок контракта, все OK (24.11.2026);
плюс расширенный анонимный прогон: **62 пути отдали данные** (§2.1), **46 путей** ответили
`{"code":401}` (§2.2). Записывающих запросов не выполнялось.

### 2.1 Без авторизации получены данные (62 пути)

| Путь | Метод | Ответ | Пример / фикстура |
|---|---|---|---|
| `release/{r_id}` | GET | `{code, release}`; у release 79 полей | 📦 `ios/tools/fixtures/release.json` (ещё `analysis/fixtures/release_1.json`) |
| `release/random`, `release/random/profile/list/{p_id}/{status}`, `release/collection/{id}/random` | GET | `{code, release}` | 📦 `analysis/fixtures/release_random.json` |
| `release/{r_id}/badges/{page}`, `release/streaming/platform/{releaseId}`, `related/{relatedId}/{page}` | GET | Paged (у релиза 1 пусто) | — |
| `filter/{page}` | GET | Paged релизов, 25/стр | 📦 `ios/tools/fixtures/filter.json` |
| `discover/hub` | GET | `{code, interesting[17], recommendations, watching[25], discussing[5], collections[7], comments[10], recommendations_page, collections_page, collections_page_count}` | 📦 `ios/tools/fixtures/discover.json` |
| `discover/watching/{page}` | GET | Paged релизов (total 83) | — |
| `episode/{releaseId}`, `episode/{releaseId}/{typeId}`, `episode/{releaseId}/{typeId}/{sourceId}` | GET | `{code, types[]}` → `{code, sources[]}` → `{code, episodes[]}` | 📦 `episode_types.json`, `episode_sources.json`, `episodes.json` |
| `episode/target/{releaseId}/{sourceId}/{position}` | GET | `{code, episode{position, name, url, iframe, quality, is_filler, is_watched}}`; url — подписанный (Kodik, `iframe: true`) | 📦 `episode_target.json` |
| `episode/updates/{releaseId}/{page}` | GET | Paged обновлений серий (total 498) | — |
| `type/all`, `type/{typeId}/channel` | GET | `{code, types[402], popular_type_ids}`; `{code, channel, articles, is_widget_eligible, ...}` | 📦 `analysis/fixtures/type_all.json` |
| `search/releases/{page}` | POST `{"query":"..."}` | Paged релизов (GET → 400) | 📦 `ios/tools/fixtures/search.json` |
| `search/collections/{page}`, `search/profiles/{page}`, `search/channels/{page}`, `search/articles/{page}` | POST `{"query":"..."}` | Paged (пустой `query` → пустая страница) | — |
| `search/feed/{page}` | POST `{"query":"..."}` | `{code, tags, channels, blogs, articles}`; сейчас `articles` — страница статей, остальные ключи `null` | — |
| `search/profileCollections/{p_id}/{page}`, `search/profile/friends/{p_id}/{page}`, `search/channel/{c_id}/subscribers/{page}` | POST | Paged | — |
| `profile/{id}` | GET | `{code, profile (93 поля), is_my_profile}` | 📦 `ios/tools/fixtures/profile.json` |
| `profile/list/all/{p_id}/{status}/{page}` | GET | Paged релизов; status 1–5 (смотрю/в планах/просмотрено/отложено/брошено) | — |
| `profile/friend/all/{id}/{page}`, `profile/{id}/badge/list`, `profile/{id}/badge/list/{categoryId}/{page}` | GET | Paged профилей; секции значков; Paged значков | — |
| `collection/hub` | GET | `{code, weekly[10], my, recommended, my_count}` | 📦 `analysis/fixtures/collection_hub.json` |
| `collection/all/{page}` | GET | Paged коллекций (total 150579) | — |
| `collection/{id}` | GET | `{code, collection (16 полей), watching_count, plan_count, completed_count, hold_on_count, dropped_count}` | — |
| `collection/{id}/releases/{page}`, `collection/all/release/{r_id}/{page}`, `collection/all/profile/{p_id}/{page}` | GET | Paged релизов / коллекций; page=0 — первая | — |
| `release/comment/all/{releaseId}/{page}`, `release/comment/{id}`, `release/comment/replies/{commentId}/{page}`, `release/comment/votes/{commentId}/{page}` | GET | Paged комментариев (total 789); одиночный комментарий приходит без `code` | — |
| `collection/comment/all/{collectionId}/{page}`, `collection/comment/{id}` | GET | Paged (total 328); одиночный комментарий без `code` | — |
| `article/comment/all/{a_id}/{page}`, `article/comment/all/{a_id}/popular`, `article/comment/{commentId}`, `article/comment/replies/{commentId}/{page}`, `article/comment/votes/{commentId}/{page}` | GET | Paged; форма элемента — как у комментария релиза | — |
| `article/{a_id}`, `article/votes/{a_id}/{page}` | GET | `{code, article (18 полей)}`; Paged голосов | — |
| `channel/{c_id}`, `channel/{c_id}/article/all/{page}` | GET | `{code, channel (34 поля), suggestion_count}`; Paged статей (total 5515) | — |
| `channel/all/{page}`, `channel/recommendations/{page}` | POST / GET | Paged каналов (у `channel/all` GET → 400) | — |
| `video/release/{releaseId}`, `video/release/categories` | GET | `{code, release, blocks, streaming_platforms, last_videos, can_appeal}`; `{code, categories[8]}` | — |
| `config/anixplayer` | GET | `{last_version_code, whats_new, download_links}` — без `code` | — |
| `role/all/{page}/{role_id}` | GET | Paged ролей (пусто в живом ответе) | — |
| `achievement/preview/{code}`, `achievement/get/{code}` | GET | `{"code":3,"achievement":null}`; `{"code":1}` | — |
| `auth/checkLogin` | POST form | `{code, available, suggested_logins}` | — |
| `auth/qr/create` | POST form | `{code, key, secret, pin, expires_in, poll_interval}` | — |

### 2.2 Только с авторизацией: проверено `{"code":401}` (46 путей)

| Путь | Метод | Ответ без токена |
|---|---|---|
| `profile/info` | GET | `{"code":401}`; форма успеха сохранена в `analysis/profile_info_shape.json` (8 полей + `code`: `channel_id`, `privilege_level`, `rating_score`, `sponsorship_expires`, `is_sponsor`, `is_perm_banned`, `is_banned`, `ban_expires`) |
| `profile/list/all/{status}/{page}` | GET | `{"code":401}` (публичная версия с `{p_id}` — §2.1) |
| `profile/preference/my`, `profile/preference/notification/my`, `profile/preference/login/info`, `profile/preference/social` | GET | `{"code":401}`; по `APIClient+Preferences.swift` ответ `preference/my` содержит настройки в snake_case и местами дубли в camelCase, `email_hint` вида `a**********0@g***l.com` |
| `history/{page}`, `favorite/all/{page}`, `favorite/add/{r_id}` | GET | `{"code":401}` |
| `collectionFavorite/all/{page}`, `collectionMy/{id}/releases` | GET | `{"code":401}` |
| `notification/count`, `notification/all/{page}`, `notification/friends/{page}`, `notification/articles/{page}`, `notification/article/comments/{page}`, `notification/collectionComments/{page}`, `notification/related/release/{page}`, `notification/releaseComments/{page}` | GET | `{"code":401}`; 📦 `analysis/fixtures/notification_count.json`. По `APIClient+Notifications.swift`: все 20 методов — `@GET`; с токеном `count` → `{code, count}`, `all/1` → пустая страница; элемент ленты полиморфный (`type`) |
| `feed/latest`, `feed/all/{page}`, `feed/latest/all/{page}` | GET | `{"code":401}`; 📦 `analysis/fixtures/feed_latest.json`, `feed_all_1.json`. По `APIClient+Feed.swift`: `feed/latest` → `{code, articleId}`, `feed/all`/`feed/latest/all` → Paged статей |
| `episode/watch/{releaseId}/{sourceId}`, `episode/watch/{releaseId}/{sourceId}/{position}`, `episode/unwatch/{releaseId}/{sourceId}`, `episode/watched`, `history/add/{r_id}/{s_id}/{position}` | GET | `{"code":401}` |
| `profile/social/{id}`, `profile/health/status`, `profile/health/enforcement/account/all/{page}` | GET | `{"code":401}` |
| `channel/{c_id}/block/all/{page}`, `channel/{c_id}/permission/all/{page}`, `channel/editor/available/all` | GET | `{"code":401}` |
| `report/release/reasons`, `report/profile/reasons` | GET | `{"code":401}` (отправка жалоб — §4) |
| `article/suggestion/all/{page}`, `article/reposts/{a_id}/{page}`, `article/vote/{a_id}/{vote}` | GET | `{"code":401}` |
| `video/appeal/profile/last`, `video/appeal/profile/{page}` | GET | `{"code":401}` |
| `import/status`, `export/bookmarks` | POST | `{"code":401}` (GET → 405) |
| `discover/recommendations/{page}` | GET | `{"code":401}` |
| `profile/list/add/{status}/{r_id}`, `notification/read`, `notification/delete/all` | GET | `{"code":401}` |

### 2.3 Особые случаи

* Пустое тело при HTTP 200 (форма ответа не подтверждена): `config/urls`,
  `channel/subscription/count`, `channel/{c_id}/editor/available`, `profile/friend/recommendations`,
  `release/random/favorite`, `profile/friend/requests/in|out/{page}`, `profile/blocklist/all/{page}`,
  `search/favorites|history|favoriteCollections|profile/list` (POST), `article/mute/{a_id}`,
  `release/vote/add/{r_id}/{vote}` (GET).
* `config/toggles` — **без параметра пустое тело, с `?version_code=26111702` полный JSON**
  (проверено 24.11.2026): `iframeEmbedUrl` (живой префикс `https://anixmirai.com/iframe?url=`),
  `kodikVideoLinksUrl`, `kodikIframeAd`, `kodikAdIframeUrl`, `sibnetUserAgent`,
  `sibnetRandUserAgent`, `impMessageText`. iOS-клиент его пока не забирает — см. §2.4.
* Записывающие методы в APK местами GET: все девять методов друзей помечены `@GET`
  (по `APIClient+Friends.swift`), включая `request/send`, `request/remove`, `request/hide`;
  `profile/preference/status/edit` — POST JSON (по `APIClient+Preferences.swift`: GET → 400,
  POST с телом → `{"code":0}`).
* Коды без документированного смысла: `achievement/get` — 1 (GET) / 4 (POST);
  `video/profile/1/{page}`, `collection/all/profile/28/{page}`, `article/comment/all/profile/...` — 1.
* `article/{id}` для удалённой/несуществующей статьи — `{"code":2,"article":null}`.
* `article/all/{page}` в API нет (GET → 400, POST → пусто); публичная лента статей —
  `search/feed/{page}` (`APIClient+Articles.swift`).

### 2.4 Плееры: что приходит в `episode/target` и какие API запрашивает клиент

Сервер не отдаёт видео: в `episode/target/{releaseId}/{sourceId}/{position}` лежит
подписанная ссылка на страницу плеера (`iframe: true`) или на поток/парсерную страницу
(`iframe: false`). Плеер выбирается по **хосту `url` и флагу `iframe`**, а не по `name`
источника (разбор dex и живые запросы — [docs/PLAYERS.md](PLAYERS.md)). Схемы и сторонние
API, снятые живыми запросами **24.11.2026**:

| Провайдер (`source.name`) | Что в `url` от Anixart | Что запрашивает клиент дальше | Проверено живым |
|---|---|---|---|
| Kodik | `kodikplayer.com/seria/{id}/{hash}/{quality}?d=&s=&ip=…`, `iframe: true` | только прокси `https://anixmirai.com/iframe?url=<urlencoded>` (внутри — iframe Kodik, Referer ставит прокси); прямой GET Kodik → HTTP 500 | прокси: 200 text/html; прямой GET: 500 |
| Sibnet | `video.sibnet.ru/shell.php?videoid=…&d=&s=&ip=…`, `iframe: false` | `shell.php` с мобильным UA из `config/toggles` → regex `src: "(.*?)"` → резолв 302 с `Referer: <shell.php>` → MP4/HLS в AVPlayer | частично: с нашей сети 403 на все UA |
| AniLibria / Libria / Liberty | `anixart.libria.fun/public/iframe.php?id={id}&ep={ep}&d=&s=&ip=…`, `iframe: false` | `https://anilibria.top/api/v1/anime/releases/{id}` → `episodes[ordinal == ep]` → `hls_1080/720/480`; фолбэк — signed `iframe.php` и разбор Playerjs (`[480p]…m3u8`); поток `cache*.libria.fun/…m3u8?countryIso=RU&…` | да: releases API 200, signed страница, m3u8 200/HLS |
| RuTube | `rutube.ru/video|play/embed|shorts|video/private/<32hex>`, `iframe: false` | `https://rutube.ru/api/play/options/{id}/?no_404=true&referer&pver=v2` с `Referer: https://rutube.ru/` → `video_balancer.m3u8` → master-плейлист в AVPlayer | да: options 200, master m3u8 200; вне RU — `detail.type == blocking_rule` |
| AnixPlayer / StudioMir (`tsm`) | ссылка `studiomir.club`/`api.studiomir.club` с `ani={id}` и `ep={n}` (реальные примеры в `episode/target` не встречались) | `https://api.studiomir.club/api?ani={ani}&apikey=80b2d3e9c4ff27eb2e924c4d38f7daec` → JSON-массив `[0].players.tsm[]` (`{episode,type,url,hls:{2160p,1080p,720p}}`, `type` TV/TR) → m3u8 в AVPlayer | API: 200 JSON; реальных источников в `episode/target` не найдено |
| YouTube | `youtube.com/watch?v=`, `youtu.be/`, `/embed/`, `/shorts/` | WKWebView с iframe `youtube.com/embed/{id}` (или YT IFrame API, как в оригинале); id вытаскивается из ссылки | в конвейере серий не встречался |
| неизвестный | любая другая HTML-страница | WKWebView с обёрткой и `Referer: https://anixart-app.com/` | — |

* Живые проверки — только запросы к API/страницам плееров (без устройства); детали,
  примеры URL и что осталось проверить — [docs/PLAYERS.md](PLAYERS.md) §2–§7 и §12.
  В iOS это `ios/Anixart/Features/Player/` (`PlaybackResolver`, `PlayerView`,
  `NativePlayerView`, `AniLibriaResolver`, `SibnetResolver`, `RutubeResolver`,
  `AnixPlayerResolver`).
* `config/toggles` (§2.3) iOS пока не запрашивает: `iframeEmbedUrl`, UA Sibnet и apikey
  StudioMir захардкожены фолбэками — это расхождение с оригиналом, а не с API.
* `episode/target` поддерживает `?download=true` (SDK `episode.ts:42`, «11 BETA 3+») —
  офлайн-ссылка для скачивания; наш клиент параметр не передаёт, форма ответа не проверена.
* **Пагинация:** все списки в §2.1–§2.2 с `{page}` — **0-based** (см. §1.3); iOS
  `APIClient` вычитает единицу (`max(page - 1, 0)`), а `total_count`/`total_page_count`
  у `filter`/`search` недостоверны — листать «пока `content` не пуст».
* **Не проверено:** релизы с реальными RuTube/AnixPlayer/YouTube-ссылками в
  `episode/target` (выборка ~50 релизов), актуальность apikey StudioMir и UA из
  `config/toggles`, воспроизведение нативных HLS на устройстве.

### 2.5 Методы: dex, живая проба и сторонний SDK

Расхождения по HTTP-методу между APK 11 beta 3, живым сервером и сторонней
TypeScript-обёрткой `anixapi` (полная сверка — [docs/SDK_CROSSCHECK.md](SDK_CROSSCHECK.md)):

| Путь | dex 11-beta-3 | Живая проба 24.11.2026 | Сторонний SDK `anixapi` | Что делать клиенту |
|---|---|---|---|---|
| `filter/{page}` | `@GET` | GET 200 (тело фильтра — query) | **POST** + JSON | оставить GET; тело фильтра SDK не нужно |
| `channel/{c_id}/article/all/{page}` | `@GET` | GET 200 | **POST** | оставить GET |
| `episode/watch/{r}/{s}/{pos}` | `@GET` | GET → `{"code":401}` (не 405) ⇒ маршрут GET | **POST** | оставить GET, не менять «по SDK» |

* Dex-аннотации `@GET`/`@POST` сверены по `APIClient+{Actions,Friends,Notifications,Preferences}.swift`
  и комментариям в них (для `episode/watch` — отдельно); для `filter/{page}` и
  `channel/{c_id}/article/all/{page}` метод подтверждён живым ответом, а не разбором dex.
* Записывающие методы в dex местами **GET**: шесть действий —
  `profile/list/add|delete/{status}/{r_id}`, `favorite/add|delete/{r_id}`,
  `release/vote/add/{r_id}/{vote}`, `release/vote/delete/{r_id}` — помечены `@GET`
  (см. `ios/Anixart/Core/APIClient+Actions.swift`); все 9 методов друзей и 20 уведомлений
  — тоже `@GET`. Успех у изменяющих операций кодируется `code` 0/2/3, а не HTTP-статусом.
* `profile/preference/status/edit` — `@POST` с JSON-телом (GET → HTTP 400, POST → `{"code":0}`);
  `auth/signIn` и все `auth/qr/*` — POST `application/x-www-form-urlencoded` (на JSON-тело
  сервер отвечает HTTP 200 с пустым телом).
* SDK описывает, похоже, другую ветку API (там же POST-поиск и `API-Version: v2`); методы и
  пагинацию из SDK не копировать — сверять с dex и живой пробой.
* Записывающие запросы (списки, избранное, оценка, заявки, настройки) живыми запросами
  не выполнялись — см. §4.1; успешные ответы известны только по dex-контракту.

## 3. Группы эндпоинтов (319 путей)



#### Релизы (12) — карточка релиза (79 полей), случайный релиз, оценки, значки, площадки стриминга, связанные релизы, избранные видео
```text
related/{relatedId}/{page}, release/collection/{id}/random, release/random, release/random/favorite, release/random/profile/list/{p_id}/{status},
release/streaming/platform/{releaseId}, release/vote/add/{r_id}/{vote}, release/vote/delete/{r_id}, release/{r_id}, release/{r_id}/badges/{page},
releaseVideoFavorite/add/{r_id}, releaseVideoFavorite/delete/{r_id}
```
#### Эпизоды, озвучки и плеер (16) — озвучки → источники → серии → подписанная ссылка на плеер (Kodik); отметки просмотра, типы и виджеты
```text
episode/target/{releaseId}/{sourceId}/{position}, episode/unwatch/{releaseId}/{sourceId}, episode/unwatch/{releaseId}/{sourceId}/{position}, episode/updates/{releaseId}/{page}, episode/watch/{releaseId}/{sourceId},
episode/watch/{releaseId}/{sourceId}/{position}, episode/watched, episode/{releaseId}, episode/{releaseId}/{typeId}, episode/{releaseId}/{typeId}/{sourceId},
type/all, type/pin/{releaseId}/{typeId}, type/unpin/{releaseId}/{typeId}, type/widget/hide/{typeId}, type/widget/unhide/{typeId},
type/{typeId}/channel
```
#### Поиск (13) — POST-поиск: релизы, коллекции, профили, каналы, статьи, лента; поиск по своим спискам, избранному, истории
```text
search/articles/{page}, search/channel/{c_id}/subscribers/{page}, search/channels/{page}, search/collections/{page}, search/favoriteCollections/{page},
search/favorites/{page}, search/feed/{page}, search/history/{page}, search/profile/friends/{p_id}/{page}, search/profile/list/{status}/{page},
search/profileCollections/{p_id}/{page}, search/profiles/{page}, search/releases/{page}
```
#### Профиль и списки (22) — профиль, публичные списки по статусам 1–5, значки, блоклист, избранное, история, роли, достижения
```text
achievement/get/{code}, achievement/preview/{code}, favorite/add/{r_id}, favorite/all/{page}, favorite/delete/{r_id},
history/add/{r_id}/{s_id}/{position}, history/delete/{r_id}, history/{page}, profile/blocklist/add/{id}, profile/blocklist/all/{page},
profile/blocklist/remove/{id}, profile/info, profile/list/add/{status}/{r_id}, profile/list/all/{p_id}/{status}/{page}, profile/list/all/{status}/{page},
profile/list/delete/{status}/{r_id}, profile/login/history/all/{id}/{page}, profile/social/{id}, profile/{id}, profile/{id}/badge/list,
profile/{id}/badge/list/{categoryId}/{page}, role/all/{page}/{role_id}
```
#### Коллекции (17) — хаб, каталог, карточка и релизы коллекции; свои и избранные коллекции
```text
collection/all/profile/{p_id}/{page}, collection/all/release/{r_id}/{page}, collection/all/{page}, collection/hub, collection/{id},
collection/{id}/releases/{page}, collectionFavorite/add/{id}, collectionFavorite/all/{page}, collectionFavorite/delete/{id}, collectionMy/all/release/{r_id}/{page},
collectionMy/create, collectionMy/delete/{collectionId}, collectionMy/edit/{collectionId}, collectionMy/editImage/{collectionId}, collectionMy/release/add/{collectionId},
collectionMy/release/remove/{collectionId}, collectionMy/{id}/releases
```
#### Комментарии (31) — к релизам, коллекциям и статьям: чтение, добавление, правка, удаление, голоса, ответы
```text
article/comment/add/{articleId}, article/comment/all/profile/{p_id}/{page}, article/comment/all/{a_id}/popular, article/comment/all/{a_id}/{page}, article/comment/delete/{commentId},
article/comment/edit/{commentId}, article/comment/process/{commentId}, article/comment/replies/{commentId}/{page}, article/comment/vote/{commentId}/{vote}, article/comment/votes/{commentId}/{page},
article/comment/{articleId}, collection/comment/add/{collectionId}, collection/comment/all/profile/{p_id}/{page}, collection/comment/all/{collectionId}/{page}, collection/comment/delete/{commentId},
collection/comment/edit/{commentId}, collection/comment/process/{commentId}, collection/comment/replies/{commentId}/{page}, collection/comment/vote/{commentId}/{vote}, collection/comment/votes/{commentId}/{page},
collection/comment/{collectionId}, release/comment/add/{releaseId}, release/comment/all/profile/{p_id}/{page}, release/comment/all/{releaseId}/{page}, release/comment/delete/{commentId},
release/comment/edit/{commentId}, release/comment/process/{commentId}, release/comment/replies/{commentId}/{page}, release/comment/vote/{commentId}/{vote}, release/comment/votes/{commentId}/{page},
release/comment/{releaseId}
```
#### Статьи (9) — карточка (текст в payload.blocks), голоса, репосты, событие, создание/правка/удаление; комментарии — в группе «Комментарии»
```text
article/create/{c_id}, article/delete/{a_id}, article/edit/pinned/{a_id}, article/edit/{a_id}, article/event,
article/reposts/{a_id}/{page}, article/vote/{a_id}/{vote}, article/votes/{a_id}/{page}, article/{a_id}
```
#### Каналы (26) — карточка, статьи, подписки, мьют, модерация участников, права, обложки и аватар
```text
channel/all/{page}, channel/avatar/upload/{c_id}, channel/blog/create, channel/blog/{p_id}, channel/cover/delete/{c_id},
channel/cover/upload/{c_id}, channel/create, channel/delete/{c_id}, channel/edit/{c_id}, channel/editor/available/all,
channel/mute/all/{page}, channel/mute/{c_id}, channel/recommendations/{page}, channel/subscribe/{c_id}, channel/subscription/all/{page},
channel/subscription/count, channel/unmute/{c_id}, channel/unsubscribe/{c_id}, channel/{c_id}, channel/{c_id}/article/all/{page},
channel/{c_id}/block/all/{page}, channel/{c_id}/block/manage, channel/{c_id}/block/{p_id}, channel/{c_id}/editor/available, channel/{c_id}/permission/all/{page},
channel/{c_id}/permission/manage
```
#### Уведомления (20) — по типам (статьи, эпизоды, друзья, комментарии, релизы), счётчик, прочтение, удаление; все методы — `@GET`, общего `delete/{id}` нет
```text
notification/all/{page}, notification/article/comments/{page}, notification/article/delete/{id}, notification/articleComment/delete/{id}, notification/articles/{page},
notification/collectionComment/delete/{id}, notification/collectionComments/{page}, notification/count, notification/delete/all, notification/episode/delete/{id},
notification/episodes/{page}, notification/friend/delete/{id}, notification/friends/{page}, notification/my/article/comment/delete/{id}, notification/my/collection/comment/delete/{id},
notification/read, notification/related/release/delete/{id}, notification/related/release/{page}, notification/releaseComment/delete/{id}, notification/releaseComments/{page}
```
#### Друзья (9) — друзья профиля, рекомендации, входящие/исходящие заявки; по dex все методы — @GET
```text
profile/friend/all/{id}/{page}, profile/friend/recommendations, profile/friend/request/hide/{id}, profile/friend/request/remove/{id}, profile/friend/request/send/{id},
profile/friend/requests/in/last, profile/friend/requests/in/{page}, profile/friend/requests/out/last, profile/friend/requests/out/{page}
```
#### Настройки (54) — profile/preference/*: приватность, уведомления, соцсети, темы, пароль и логин; удаление профиля; config/*
```text
config/anixplayer, config/toggles, config/urls, profile/deletion/cancel, profile/deletion/request,
profile/deletion/status, profile/preference/avatar/delete, profile/preference/avatar/edit, profile/preference/badge/edit/{id}, profile/preference/badge/remove,
profile/preference/badge/showcase/pin/{id}, profile/preference/badge/showcase/reorder, profile/preference/badge/showcase/unpin/{id}, profile/preference/email/change, profile/preference/email/resend,
profile/preference/email/verify, profile/preference/google/bind, profile/preference/google/unbind, profile/preference/login/change, profile/preference/login/history/delete,
profile/preference/login/info, profile/preference/my, profile/preference/notification/article/edit, profile/preference/notification/comment/edit, profile/preference/notification/episode/edit,
profile/preference/notification/episode/first/edit, profile/preference/notification/my, profile/preference/notification/my/article/comment/edit, profile/preference/notification/my/collection/comment/edit, profile/preference/notification/related/release/edit,
profile/preference/notification/release/all/{page}, profile/preference/notification/release/type/edit, profile/preference/notification/release/type/{releaseId}, profile/preference/notification/report/process/edit, profile/preference/notification/selected/releases/edit,
profile/preference/notification/status/edit, profile/preference/notification/type/edit, profile/preference/password/change, profile/preference/privacy/counts/edit, profile/preference/privacy/friendRequests/edit,
profile/preference/privacy/incognito/edit, profile/preference/privacy/social/edit, profile/preference/privacy/stats/edit, profile/preference/section/edit, profile/preference/social,
profile/preference/social/edit, profile/preference/status/edit, profile/preference/telegram/bind, profile/preference/telegram/unbind, profile/preference/themes/edit,
profile/preference/vk/bind, profile/preference/vk/unbind, profile/preference/yandex/bind, profile/preference/yandex/unbind
```
#### Импорт/экспорт (3) — перенос закладок: экспорт, импорт (POST), статус импорта
```text
export/bookmarks, import/bookmarks, import/status
```
#### Модерация и репорты (35) — жалобы и причины для всех типов контента, санкции и апелляции, предложки статей, апелляции видео
```text
article/mute/{a_id}, article/suggestion/all/{page}, article/suggestion/create/{b_id}, article/suggestion/delete/{a_id}, article/suggestion/edit/{a_id},
article/suggestion/publish/{a_id}, article/unmute/{a_id}, profile/health/enforcement/account/all/{page}, profile/health/enforcement/content/all/{page}, profile/health/enforcement/{id},
profile/health/enforcement/{id}/appeal, profile/health/status, profile/process/{id}, report/article, report/article/reasons,
report/channel, report/channel/reasons, report/collection, report/collection/reasons, report/comment/article,
report/comment/article/reasons, report/comment/collection, report/comment/collection/reasons, report/comment/release, report/comment/release/reasons,
report/episode, report/episode/reasons, report/profile, report/profile/reasons, report/release,
report/release/reasons, video/appeal/add, video/appeal/delete/{appealId}, video/appeal/profile/last, video/appeal/profile/{page}
```
#### Каталог, лента, фильтры (7) — главная (discover/hub), «сейчас смотрят», рекомендации (вход), лента, каталог
```text
discover/hub, discover/recommendations/{page}, discover/watching/{page}, feed/all/{page}, feed/latest,
feed/latest/all/{page}, filter/{page}
```
#### Видео (24) — видео релиза (категории, площадки), видео профиля; video/{fmt} — форма ответа не проверена
```text
video/3gpp, video/av01, video/avc, video/avi, video/divx,
video/dv_hevc, video/hevc, video/hevcdv, video/mjpeg, video/mp2p,
video/mp2t, video/mp4, video/mp42, video/mp43, video/mpeg,
video/mpeg2, video/mpeg4, video/mpg, video/profile/{p_id}/{page}, video/raw,
video/release/categories, video/release/{releaseId}, video/webm, video/wvc1
```
#### Служебные и auth (21) — вход, регистрация, QR, провайдеры, restore, checkLogin, аналитика, краш-логи
```text
analytics/startup, api/crash/upload, api/perf/upload, auth/checkLogin, auth/firebase,
auth/google, auth/qr/confirm, auth/qr/create, auth/qr/decline, auth/qr/open,
auth/qr/status, auth/resend, auth/restore, auth/restore/resend, auth/restore/verify,
auth/signIn, auth/signUp, auth/telegram, auth/verify, auth/vk,
auth/yandex
```
## 4. Неизвестно и не проверено

### 4.1 Требуют входа; успешный сценарий этим документом не проверен

Все записывающие методы: `*/add|delete|edit|process|vote`, `episode/watch|unwatch`,
`history/add|delete`, `notification/read|delete/all|*/delete`, `favorite/*`,
`profile/list/add|delete`, `profile/friend/request/*`, `profile/blocklist/add|remove`,
`channel/subscribe|unsubscribe|mute|unmute`, `type/pin|unpin|widget/*`,
`article/create|edit|delete|mute|unmute|suggestion/*`, `collectionMy/*`,
`collectionFavorite/add|delete`, `report/*`, `video/appeal/add|delete`, настройки
(`*/edit|change|bind|unbind`), `profile/deletion/*`, `import/bookmarks`. Формы запросов
и успешные ответы описаны только dex-контрактом и моделями в `APIClient+*.swift`;
живыми запросами они не вызывались.

### 4.2 Форма ответа не подтверждена

Пустое тело или пустые списки без объяснения: `config/toggles`, `config/urls`,
`channel/subscription/count`, `channel/{c_id}/editor/available`,
`profile/friend/recommendations`, `profile/friend/requests/in|out/{page}`,
`profile/blocklist/all/{page}`, `search/favorites|history|favoriteCollections|profile/list`,
`article/mute/{a_id}`, `release/random/favorite`. Уведомления и заявки у тестового
аккаунта пустые, поэтому форма их элементов живым ответом не подтверждена.

### 4.3 Не проверялись вовсе

`auth/firebase|google|telegram|vk|yandex`, `auth/signUp|verify|resend|restore*`,
`auth/qr/open|confirm|decline` (положительный сценарий), `analytics/startup`,
`api/crash/upload`, `api/perf/upload`, `video/{fmt}` (24 пути), `video/profile/{p_id}/{page}`,
`video/appeal/add|delete`, `channel/create|edit|delete|avatar|cover|mute|editor|blog`,
`profile/preference/*` (запись), `profile/deletion/*`, `profile/health/enforcement/{id}`,
`report/*` (отправка), `article/create|edit|delete`, `article/suggestion/*`,
`collectionMy/*`, `collectionFavorite/add|delete`, `notification/*/delete`,
`import/bookmarks`, `export/bookmarks` (успешный ответ), `type/pin|unpin|widget/*`.

### 4.4 Ограничения методики и расхождения

* Из 319 путей живыми запросами проверено 108: **62** отдали данные (§2.1), **46**
  ответили `{"code":401}` (§2.2). Остальные **211** путей живым запросом не проверялись.
* Сервер сообщает об ошибках телом при HTTP 200 — клиент обязан проверять `code`,
  а не только статус.
* Страницы нумеруются с 0, а iOS-`APIClient` по умолчанию шлёт `page = 1`.
* `total_count`/`total_page_count` у `filter/{page}` и `search/releases/{page}`
  не отражают пагинацию (§1.3).
* Успешный вход: `ios/README.md` всё ещё пишет «не проверен живым аккаунтом», а
  `ios/ROADMAP.md` и комментарии в `APIClient+Friends.swift` — что проверен на аккаунте
  `<test-login>`. В этом документе положительные ответы защищённых эндпоинтов описаны по
  фикстурам/коду, а не по собственному входу.
* API неофициальный: контракт может измениться, проверять через
  `python ios/tools/api_probe.py`.

## 5. Чем проверено

* `python ios/tools/api_probe.py` — 13 проверок (каталог, поиск, релиз, профиль, серии,
  ссылка на плеер, коллекции, комментарии, `401`), все OK 24.11.2026.
* Расширенный анонимный прогон: более 150 GET/POST-запросов без записи; 62 пути с данными,
  46 путей с `{"code":401}`, остальные — проверка методов (400/405), кодов 1–4
  и пустых ответов.
* Фикстуры: `ios/tools/fixtures/` — 9 файлов (`tools/fetch_fixtures.py`), `analysis/fixtures/` —
  14 файлов (сняты 21.11.2026).
* Расширения `APIClient+Articles/Feed/Friends/Preferences/Notifications` и
  `Features/Auth/QrLoginView.swift`
  — источники фактов о dex-аннотациях (методы, типы ответов) и о живых пробах
  (пометки в комментариях кода); в тексте такие факты атрибутированы.

Связанные документы: `ios/PORTING.md` (разбор APK), `ios/ROADMAP.md` (паритет),
`docs/ARCHITECTURE.md` (устройство клиента).
