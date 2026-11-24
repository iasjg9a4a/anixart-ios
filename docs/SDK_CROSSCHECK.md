# Сверка Reference-SDK `anixapi` с iOS-клиентом

Сверка сторонней TypeScript-обёртки Anixapp-Community/anixapi (рабочая копия —
`C:\things\harnessshit\anixapi-ref`) с нашим клиентом. Цель — не «переписать по SDK», а найти
**эндпоинты, которые SDK использует, а мы нет**, и **поля моделей**, которые мы теряем или объявили неверно.

## 1. Источники и метод

| Что | Где | Объём |
|---|---|---|
| Наш клиент | `ios/Anixart/Core/APIClient*.swift` (6 файлов) | 40 вызовов `request("…")`, 39 уникальных путей + 3 пути дружбы в `friendRequestMutation` = **42 эндпоинта** |
| SDK | `anixapi-ref/src/api/**/*.ts` | 320 литералов `path: ...`, **314 уникальных путей** |
| APK 11-beta-3 (dex) | `analysis/endpoints.txt` | 319 путей |
| Живые ответы | `ios/tools/fixtures/*.json`, `analysis/fixtures/*.json` | 23 фикстуры (release, filter, search, episode, discover, collection_hub, profile) |
| Проверенные факты | `docs/API.md` | методы, коды, пагинация |

Извлечение путей SDK и наших вызовов:

```powershell
# SDK: пути
Select-String -Path 'anixapi-ref\src' -Recurse -Pattern 'path:\s*`([^`]+)`' -AllMatches
# Мы: вызовы
Select-String -Path 'anixart\ios\Anixart' -Recurse -Pattern 'request\("([^"]+)"' -AllMatches
```

Главный вывод по путям: **все 42 наших эндпоинта в SDK есть**. Расхождения — в HTTP-методе,
query-параметрах, заголовке `API-Version` и (сильнее всего) в **форме ответа**: SDK декодирует
больше полей, чем объявлено у нас.

## 2. Таблица эндпоинтов

`Наш вызов` — файл:строка; `SDK` — файл:строка. Жирным — то, что стоит проверить/поправить.

| Эндпоинт | Наш вызов | Мы | SDK (файл) | SDK (метод) | Расхождение |
|---|---|---|---|---|---|
| `discover/hub` | `APIClient.swift:69` | GET | `discover.ts:24` | GET | форма ответа: у нас 4 поля из 9 (§3.3) |
| `filter/{page}` | `APIClient.swift:76` | GET | `release/filter.ts:21` | **POST** + JSON | метод; GET проверен (`API.md:142`). Тела фильтра (`sort`, `genres`, `status_id`) у нас нет |
| `search/releases/{page}` | `APIClient.swift:84` | POST JSON | `search.ts:179` | POST JSON + `apiV2` | **заголовок `API-Version: v2`** не отправляем; тело без `searchBy` |
| `release/{id}` | `APIClient.swift:90` | GET | `release/release.ts:86` | GET | SDK умеет `?details=false` (`:101`) и `extended_mode` — не используем |
| `episode/{r}` | `APIClient.swift:96` | GET | `release/episode.ts:97` | GET | — |
| `episode/{r}/{typeId}` | `APIClient.swift:102` | GET | `episode.ts:84` | GET | — |
| `episode/{r}/{typeId}/{sourceId}` | `APIClient.swift:108` | GET | `episode.ts:71` | GET | query `sort` (SDK `Source.getEpisodes(sort=1)`) не передаём |
| `episode/target/{r}/{s}/{pos}` | `APIClient.swift:116` | GET | `episode.ts:21` | GET | SDK ещё `?download=true` (`:42`, 11 BETA 3+) — офлайн-ссылка |
| `profile/{id}` | `APIClient.swift:123` | GET | `profile/profile.ts:60` | GET | — |
| `profile/list/all/{status}/{p}` | `APIClient.swift:129` | GET | `profileList.ts:49` | GET | query `sort`, `filter_announce` не передаём |
| `history/{p}` | `APIClient.swift:136` | GET | `release/history.ts:47` | GET | — |
| `favorite/all/{p}` | `APIClient.swift:143` | GET | `release/favorite.ts:49` | GET | query `sort`, `filter_announce` |
| `search/collections/{p}` | `APIClient.swift:151` | POST JSON | `search.ts:60` | POST JSON | тело без `searchBy` |
| `search/profiles/{p}` | `APIClient.swift:159` | POST JSON | `search.ts:151` | POST JSON | тело без `searchBy` |
| `collection/{id}` | `APIClient.swift:165` | GET | `collection/collection.ts:36` | GET | форма `CollectionResponse` (§3.3) |
| `collection/{id}/releases/{p}` | `APIClient.swift:171` | GET | `collection.ts:90` | GET | — |
| `notification/count` | `APIClient.swift:177` | GET | `notification/notification.ts:73` | GET | — |
| `episode/watch/{r}/{s}/{pos}` | `APIClient.swift:184` | GET | `episode.ts:149` | **POST** | метод; dex `@GET` и живая проба → `401`, не `405` (`API.md:184`) ⇒ GET маршрутизируется. **Не менять без проверки** |
| `history/add/{r}/{s}/{pos}` | `APIClient.swift:190` | GET | `history.ts:21` | GET | — |
| `collection/hub` | `APIClient.swift:196` | GET | `collection.ts:23` | GET | нет `my_count` (§3.3) |
| `collection/all/{p}` | `APIClient.swift:202` | GET | `collection.ts:49` | GET | SDK-обёртка передаёт `sort=2` (`client.ts:148`), мы — без sort |
| `release/comment/all/{r}/{p}` | `APIClient.swift:209` | GET | `releaseComment.ts:48` | GET | query `sort` не передаём |
| `auth/signIn` | `APIClient.swift:226` | POST form | `auth/auth.ts:176` | POST form | — (коды 2/3 = `LoginResult`, совпадает) |
| `feed/latest` | `APIClient+Feed.swift:22` | GET | `feed.ts:34` | GET | ключ ответа: SDK `article_id` (`types/config.ts:55`), APK `articleId`; наш декодер берёт оба — **оставить** |
| `feed/all/{p}` | `APIClient+Feed.swift:33` | GET | `feed.ts:21` | GET + query | — |
| `search/feed/{p}` | `APIClient+Feed.swift:46`, `APIClient+Articles.swift:384` | POST JSON | `search.ts:99` | POST JSON | — |
| `article/{id}` | `APIClient+Articles.swift:400` | GET | `channel/article.ts:28` | GET | — |
| `article/comment/all/{a}/{p}` | `APIClient+Articles.swift:410` | GET | `articleComment.ts:48` | GET | — |
| `channel/{c}/article/all/{p}` | `APIClient+Articles.swift:392` | GET | `channel/channel.ts:21` | **POST** | метод; наш GET проверен живым (`API.md:164`) — оставить |
| `profile/friend/all/{id}/{p}` | `APIClient+Friends.swift:38` | GET | `profileFriend.ts:21` | GET | — |
| `profile/friend/requests/in/{p}` | `APIClient+Friends.swift:45` | GET | `profileFriend.ts:86` | GET | элемент: SDK `IProfile`, у нас `FriendRequest` (§3.6) |
| `profile/friend/requests/out/{p}` | `APIClient+Friends.swift:52` | GET | `profileFriend.ts:112` | GET | то же |
| `profile/friend/recommendations` | `APIClient+Friends.swift:63` | GET | `profileFriend.ts:34` | GET | — |
| `profile/friend/request/send/{id}` | `APIClient+Friends.swift:72` | GET | `profileFriend.ts:73` | GET | **`successCodes: [0,2,3]`** — у нас 2/3 бросают ошибку (§4.1) |
| `profile/friend/request/remove/{id}` | `APIClient+Friends.swift:78` | GET | `profileFriend.ts:60` | GET | то же |
| `profile/friend/request/hide/{id}` | `APIClient+Friends.swift:82` | GET | `profileFriend.ts:47` | GET | — |
| `notification/all/{p}` | `APIClient+Notifications.swift:51` | GET | `notification.ts:21` | GET | — |
| `notification/read` | `APIClient+Notifications.swift:69` | GET | `notification.ts:246` | GET | — |
| `notification/delete/all` | `APIClient+Notifications.swift:77` | GET | `notification.ts:86` | GET | — |
| `notification/{type}/delete/{id}` | `APIClient+Notifications.swift:87` | GET | `notification.ts:281` | GET | 9 путей совпадают; расходится дискриминатор `type` (§3.5) |
| `profile/preference/my` | `APIClient+Preferences.swift:211` | GET | `profilePreference.ts:165` | GET | — |
| `profile/preference/notification/my` | `APIClient+Preferences.swift:234` | GET | `notificationPreference.ts:73` | GET | — |
| `profile/preference/status/edit` | `APIClient+Preferences.swift:225` | POST JSON | `profilePreference.ts:301` | POST JSON | — |

**Расхождения по методу — ровно три** (`filter`, `channel/{c}/article/all`, `episode/watch`), и все три
у нас подтверждены живыми запросами. Менять метод «по SDK» нельзя: SDK, вероятно, описывает
другую ветку API (см. §5).

**Что общего и важно:** SDK считает страницы **как передали** — примеры в JSDoc начинаются с `1`
(`feed.feed(1)`), тогда как живой API нумерует с нуля (`docs/API.md:95`). Наш `max(page - 1, 0)`
верен; при переносе кода из SDK эту разницу легко унаследовать.

## 3. Модели: что объявлено неверно / отсутствует / лишнее

Сверялись: `ios/Anixart/Models/Models.swift`, `ios/Anixart/Core/APIClient+Articles.swift`,
`APIClient+Notifications.swift`, `APIClient+Friends.swift` — против `src/types/*.ts` и живых фикстур.

### 3.1 Release (`Models.swift:14`)

Верно: `title_ru/title_original/title_alt`, `image`, `description`, `release_date`,
`episodes_released/episodes_total`, `is_adult/is_play_disabled/is_deleted`, `comment_count`,
`favorites_count`, `vote_count`, `screenshot_images`, `related_releases`, `recommended_releases`,
`profile_list_status`, `last_view_episode` — всё есть в `IRelease` (`types/release.ts:114`).

**Отсутствует** (есть в `IRelease` и в `ios/tools/fixtures/release.json`):
`@id`, `poster`, `related` (франшиза), `season`, `broadcast`, `creation_date`, `last_update_date`,
`aired_on_date`, `your_vote`, `is_viewed`, `is_favorite`, `is_view_blocked`, `is_tpp_disabled`,
`age_rating`, `status_id`, `watching_count`/`plan_count`/`completed_count`/`hold_on_count`/`dropped_count`,
`related_count`, `comments_count`, `collection_count`, `comment_per_day_count`, `vote_1_count`…`vote_5_count`,
`episode_last_update`, `video_banners`, `badge_count`, `badges_preview`, `screenshot_animations`,
`profile_release_type_notification_preference_count`, `is_release_type_notifications_enabled`.

Приоритет для UI: `is_viewed`, `is_favorite`, `your_vote`, `status_id`, `related` (id франшизы для
`related/{relatedId}/{page}`), `watching_count`/`plan_count`/`completed_count`/`hold_on_count`/`dropped_count`.

**Спорно:** `LastViewEpisode` (`Models.swift:374`) объявляет ключи `releaseId`/`sourceId` без raw-value,
а `ILastWatchedEpisode` (`types/release.ts:499`) описывает элемент как
`release_id`/`source_id`/`episode_id`/`type_id`/`timestamp` (а `IRelease.last_view_episode` —
вообще `IEpisode`). В живом `release/1` поле `null`, проверить нечем. Если сервер шлёт snake_case,
все поля молча останутся `nil`.

### 3.2 Profile / ProfileBrief (`Models.swift:139`, `:448`)

Верно: `id/login/avatar/status/register_date/is_verified/is_sponsor` + все счётчики списков
и `watched_episode_count/comment_count/collection_count` — совпадает с `ios/tools/fixtures/profile.json`.

**Отсутствует:** `last_activity_time`, `privilege_level`, `rating_score`, `friend_count`,
`subscription_count`, `video_count`, `watched_time`, `badge`/`badge_count`/`badges_preview`,
`friends_preview`, `collections_preview`, `comments_preview`, `release_videos_preview`,
`history`, `votes`, `roles`, `watch_dynamics`, `vk_page`…`discord_page`, `ban_expires`/`ban_reason`,
`is_private`, `is_banned`/`is_perm_banned`, `is_incognito`, `is_deleted`, `friend_status`,
`is_blocked`/`is_me_blocked`, `is_stats_hidden`/`is_counts_hidden`/`is_social_hidden`,
`is_friend_requests_disallowed`, `is_online`, `sponsorshipExpires`, `theme_*`, `pinned_section_id`.

`ProfileBrief` против `IProfileShort` (`types/profile.ts:164`): нет `friend_status` (нужен кнопке
«добавить/удалить из друзей»), `friend_count`, `badge_id`, `badge_type`, `is_banned`, `privilege_level`.

### 3.3 Collection / hub / Discover (`Models.swift:470`, `:495`, `:385`, `:347`)

* **Ошибка:** `Collection.creatorId` ← `"creator_id"`. Такого поля в ответе **нет**: приходит
  `creator` — объект профиля (`analysis/fixtures/collection_hub.json`). Поле всегда `nil`;
  заменить на `creator: ProfileBrief?` (id брать из него).
* **Отсутствует:** `@id`, `creator`, `creation_date`, `last_update_date`, `is_deleted`, `releases`,
  `releases_preview`, `watched_count`, `has_release` (`ICollection`, `types/collection.ts:6`).
* `CollectionResponse` (`:495`): SDK и живой ответ дают `watching_count, plan_count, completed_count,
  hold_on_count, dropped_count` — у нас объявлены только первые два.
* `CollectionsHubResponse` (`:385`): нет `my_count` (`ICollectionHubResponse.my_count`).
* `Discover` (`:347`): нет `recommendations`, `comments` (готовый блок «комментарии недели», 10 шт.),
  `recommendations_page`, `collections_page`, `collections_page_count` — всё есть в
  `analysis/fixtures/discover_hub.json` и `types/release.ts:410`.
* `InterestingItem` (`:356`) совпадает с живым ответом — трогать не нужно.

### 3.4 Article (`APIClient+Articles.swift:24`, `:108`)

* `Article` против `IArticle` (`types/channel.ts:168`): нет `under_moderation_reason`,
  `is_under_moderation`.
* Наоборот, у нас есть, а в SDK-типах нет: `is_signed`, `is_pinned`, `is_muted`,
  `has_delete_enforcement`, `popular_comment`, `payload.version`, `payload.block_count`.
  По живым ответам это поля API — **не удалять**; SDK-типы просто неполные.
* `ArticleChannel` (`:108`): нет `is_blocked`, `block_reason`, `block_expire_date`, `is_perm_blocked`,
  `is_administrator_or_higher`. Лишнее: `is_muted` — в `IChannel` такого поля нет (сверить с APK).
* Комментарии статьи используют `ReleaseComment` (`Models.swift:280`), в котором нет `type` и
  `parent_comment_id` (`IBaseComment`) и `posted_at_episode` (`IReleaseComment`) — без них не
  построить ответы на комментарии.

### 3.5 Notification (`APIClient+Notifications.swift:125`)

* `type` + `timestamp` + `is_new` + `is_pushed` — совпадает с `IBaseNotification`.
* **Расходится:** `status` объявлен `Int?`, SDK — `IFriendNotification.status: string`
  (`types/notification.ts:21`). Живой ленты нет (0 уведомлений), поэтому один из двух источников
  ошибается — проверить на непустом аккаунте.
* `article`-уведомление: SDK `IArticleNotification.article: number`; у нас поля нет — некуда
  вести переход по статье.
* friend-уведомления: SDK типизирует `profile`/`by_profile` как полный `IProfile`, у нас `ProfileBrief`.
* **Риск:** `Kind.rawValue` (`myCollection`, `myArticle`) — из APK; `DeleteNotificationType`
  (`types/notification.ts:106`) использует `my/collection/comment` и `my/article/comment`. Если сервер
  в `type` шлёт второй вариант, `kind == nil` и `delete()` бросает `badURL`
  (`APIClient+Notifications.swift:96`).
* `is_read` в API нет, только `is_new` — наш `isRead = !is_new` логически верен.

### 3.6 FriendRequest (`APIClient+Friends.swift:112`)

* Обёртки `{id, profile, timestamp}` в SDK **нет**: `requests/in|out` типизированы как
  `IPageableResponse<IProfile>` (`profileFriend.ts:86`, `:112`), т.е. элемент — сам профиль.
  Наш fallback (`:126-131`) это покрывает, но `timestamp` останется `nil`.
* Теряем `friend_status` из `IProfileShort`/`IFriendRequestResponse` — это новое состояние дружбы,
  нужное интерфейсу.
* `send`/`remove` отвечают `{code, friend_status}` (`IFriendRequestResponse`), а мы декодируем
  только `ServerCode` — `friend_status` теряем.

### 3.7 Episode / EpisodeType / EpisodeSource (`Models.swift:206`, `:223`, `:238`)

По живым фикстурам наши ключи **верны там, где SDK ошибается**:

| Поле | Живой ответ | У нас | SDK |
|---|---|---|---|
| `is_filler` | есть (`episode_target.json`) | ✓ `is_filler` | ✗ `is_filter` → `isFilter` всегда `undefined` |
| `episodes_count` | есть (`episode_types.json`, `episode_sources.json`) | ✓ `episodes_count` | ✗ `episode_count` → `Dubber.episodeCount` `undefined` |
| `quality` у серии | есть (`episode_target.json`) | ✓ | ✗ нет в `IEpisode` |

Отсутствует: `Episode.@id` (сейчас `id` собирается как `"\(sourceId)-\(position)"`, `Models.swift:251`);
`EpisodeType` — `channel_id`, `view_count`, `pinned`, `quality`, `@id`; `EpisodeSource` —
`is_download_disabled`, `download_speed_limit`, `@id`.

## 4. Что взять из SDK

1. **`successCodes: [0, 2, 3]` для заявок в друзья** (`profileFriend.ts:60,73`). Сейчас
   `friendRequestMutation` вызывает `check(code)` (`APIClient.swift:258`) и **бросает ошибку на
   успешный ответ**: код 2 — «заявка подтверждена»/«заявка отменена», 3 — «заявка отправлена»/«дружба
   удалена» (`SendFriendRequestResult`, `RemoveFriendRequestResult`). Это баг, а не улучшение.
2. **`feed/latest/all/{page}`** (`feed.ts:47`) — постраничная лента статей. У нас есть только
   `feed/latest` → `articleId`; вторая страница ленты недоступна.
3. **`episode/watched?release_ids=1,2,3`** (`episode.ts:56`) → `IWatchedSource[]`
   (`{release_id, source_id, positions[]}`) — синхронизация «просмотрено» одним запросом вместо N.
4. **`history/delete/{r_id}`** (`history.ts:34`) — сейчас нельзя убрать релиз из истории.
5. **Избранное и закладки на запись:** `favorite/add|delete/{r_id}` (`favorite.ts:20,33`),
   `profile/list/add|delete/{status}/{r_id}` (`profileList.ts:20,33`) — у нас только чтение.
6. **`episode/unwatch/{r}/{s}[/{pos}]`** (`episode.ts:109,122`) — снять отметку просмотра.
7. **`related/{relatedId}/{page}`** (`release/related.ts:21`) + заголовок `API-Version: v2` —
   постраничные «похожие» вместо только встроенного `related_releases`.
8. **`config/urls` + `config/toggles`** (`config.ts:81,61`) — `api_urls[]`, `static_domain`,
   `*_auth_available`, `minVersionCode` вместо захардкоженного `baseURL` (`APIClient.swift:49`).
9. **Точные enum-коды** вместо `APIError.api(code)`: `SendFriendRequestResult` (2…9),
   `CommentAddResult` (2…8), `CollectionResult` (2…4), `FavoriteResult` (2,3),
   `LoginResult` уже используется. Даст человекочитаемые ошибки.
10. **`LONG_CODE_HEADER` (`X-Long-Code: 1`)** и `ICodeInputResponse` (`code_length`,
    `code_time_left`, `types/auth.ts:49-57`) — 5-значные коды подтверждения; пригодится, если
    появится регистрация/восстановление. Плюс `search/articles/{page}` (POST) — поиск по статьям.

## 5. Где SDK устарел или расходится с живым API

1. **`IDubber`/`ISource` → `episode_count` вместо `episodes_count`** — `Dubber.episodeCount`
   (`classes/Dubber.ts:21`) и `Source.episodeCount` (`classes/Source.ts:16`) всегда `undefined`.
   Живой ответ: `episode_types.json`, `episode_sources.json`.
2. **`IEpisode.is_filter` вместо `is_filler`** — `Episode.isFilter` (`classes/Episode.ts:26`) всегда
   `undefined`.
3. **`DEFAULT_VERSION_CODE = 26080522`** (Anixart 9.0 BETA 21, `types/config.ts:4`) при README
   «актуально под Anixart 11 BETA 3». Значит, `config/urls` и `config/toggles` запрашиваются
   с устаревшим `version_code` по умолчанию.
4. **`USER_AGENT = "AnixartApp/10.5-26101718"`** (`client.ts:21`) — UA от 10.5, хотя README
   заявляет 11 BETA 3. Для серверных экспериментов это важнее, чем кажется.
5. **`ILatestArticleResponse.article_id`** (`types/config.ts:55`) против APK-класса `LatestArticleResponse`
   без `@JsonProperty` → `articleId`. Наш декодер (`APIClient+Feed.swift:125`) принимает оба ключа —
   это правильный компромисс.
6. **`IRelease.last_view_episode: IEpisode`**, хотя рядом есть `ILastWatchedEpisode` с другой формой
   (`release_id`, `source_id`, `episode_id`, `type_id`) — SDK сам себе противоречит.
7. **`IProfile.release_video_preview`** (`types/profile.ts:54`), а живой профиль отдаёт
   `release_videos_preview` (`ios/tools/fixtures/profile.json`).
8. **`IFeedSearchResponse`** (`types/channel.ts:230`) объявляет `articles`, `channels`, `blogs`, `tags`
   обязательными; живой `search/feed` отдаёт три из четырёх `null` (`APIClient+Feed.swift:38-43`).
   SDK-типы здесь нельзя использовать как контракт.
9. **`IRelease` — «все поля обязательны»**, но в списках (`ios/tools/fixtures/search.json`) релиз
   приходит с 40 ключами из 79, что в `release.json`. Наша модель «почти всё опционально» точнее.
10. **Методы `filter/{page}` и `channel/{c}/article/all/{page}` — POST в SDK**, а живой бэкенд отвечает
    на GET (`API.md:142`, `API.md:164`). Аналогично `episode/watch` — POST в SDK против `@GET` в dex
    11-beta-3. Вывод: **методы из SDK не копировать**, сверять с dex и живой пробой.
11. **Пагинация:** SDK нигде не сдвигает `page` и в примерах стартует с `1`; живой API нумерует с
    нуля. Готовый код из SDK даст «вторую страницу» вместо первой.

## 6. Порядок внедрения

1. Починить `check` для заявок в друзья (п. 4.1) — это текущий баг, а не новая функциональность.
2. Дополнить модели **без изменения запросов**: `Collection.creator`, `CollectionResponse`
   (`completed/hold_on/dropped`), `CollectionsHubResponse.my_count`, `Discover` (5 полей),
   `Release` (`is_viewed/is_favorite/your_vote/status_id/related`), `ProfileBrief.friend_status`.
3. Добавить дешёвые эндпоинты: `feed/latest/all`, `episode/watched`, `history/delete`,
   `episode/unwatch`, `favorite/*`, `profile/list/*`.
4. Только после этого — эксперименты с `API-Version: v2` (`search/releases`, `related`) и query
   `sort`/`filter_announce`, с проверкой формы ответа по `ios/tools/fixtures`.
