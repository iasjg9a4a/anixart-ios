# Плееры Anixart 11 beta 3: как оригинальное Android-приложение воспроизводит видео
Документ для iOS-разработчика: что отдаёт API для каждой серии, как клиент-оригинал
(`com.swiftsoft.anixartd`, APK 11 BETA 3) превращает это в видео и что нужно повторить, чтобы плеер
вёл себя так же. Источники: `analysis/strings.txt` (ссылки вида `analysis/strings.txt:198328`),
`analysis/endpoints.txt`; `analysis/fixtures/episode_*.json`; `analysis/unpacked/classes*.dex`
(дизассемблировано androguard 4.1.4, имена классов в тексте); `analysis/unpacked/assets/`
(HTML/JS-плееры, adblock) и живые запросы к `https://api-s.anixsekai.com/` и самим плеерам,
снятые **24.11.2026**. Примеры URL — реальные ответы `episode/target/...`. Подписи `d=` (похоже на
`YYYYMMDDHH`), `s=`, `ip=` привязаны к IP и живут ограниченное время (по наблюдению `d` обновляется
каждый час); ссылку запрашивать перед каждым запуском.

## 1. Общий конвейер: от серии до видео
1. `GET episode/{releaseId}` → `{code, types[]}`; `GET episode/{releaseId}/{typeId}` → `{code, sources[]}`
   (у источника `name` «Kodik»/«Sibnet»/«Libria»…, `episodes_count`, `quality`, `is_download_disabled`).
2. `GET episode/{releaseId}/{sourceId}/{position}` → `{code, episode{position, name, url, iframe, quality}}`.
   **`name` источника — только подпись: плеер выбирается по хосту `url`, а не по `name`.**
3. Сервер сам кладёт в `url` подписанную ссылку плеера и выставляет `iframe`:

| release | source `name` | `url` (сокращённо) | `iframe` | Кто играет |
|---|---|---|---|---|
| 1 | Kodik | `https://kodikplayer.com/seria/175268/<hash>/720p?d=…&s=…&ip=…` | `true` | WebView + iframe-прокси |
| 1562 | Sibnet | `https://video.sibnet.ru/shell.php?videoid=2665039&d=…&s=…&ip=…` | `false` | нативный парсер → ExoPlayer |
| 1562 | Libria | `https://anixart.libria.fun/public/iframe.php?id=1243&ep=1&d=…&s=…&ip=…` | `false` | нативный парсер → ExoPlayer |
| 20306 | Liberty | `https://anixart.libria.fun/public/iframe.php?id=10312&ep=1&…` | `false` | то же, что Libria |
| 92 | Sovet (не работает) | `https://sovetromantica.com/embed/episode_982_1-dubbed?d=…&s=…&ip=…` | `true` | WebView + iframe-прокси |
| 1034 | Sibnet | `https://vk.com/video_ext.php?gid=5&oid=-23081559&id=166455867&hash=…` | `false` | VKVideoParser (по хосту `vk.com`) |

4. `iframe == true` → `WebPlayerActivity` (WebView). `iframe == false` → фабрика `Parser` выбирает
   парсер по хосту, достаёт ссылки в `LinkedHashMap` качеств и запускает `SwiftPlayerActivity`
   (AndroidX Media3/ExoPlayer).
5. `{code:1, episode:null}` — у источника нет серий (release 5: у Sibnet `episodes[]` пуст, position 1–3 → код 1).

### 1.1. Фабрика парсеров (хост → класс)
`Parser.<clinit>` хранит массивы хостов, фабричный метод `Parser$Companion.IlIl1II1I(String)`
выбирает парсер (`analysis/strings.txt:172392-172423`). Соответствие хостов и классов:
`kodikplayer.com`/`kodik.cc`/`kodik.info`/`aniqit.com` → `KodikParser`;
`video.sibnet.ru` → `SibnetParser` (`:198334`, `:206011`);
`anilibria.top`/`anilibria.tv`/`new.anilib.one`/`anixart.libria.fun` → `AniLibriaParser`
(`:192172`, `:192173`, `:192185`); `rutube.ru` → `RuTubeParser` (`:203280`);
`studiomir.club`/`api.studiomir.club` → `StudioMirParser` (`:205225`);
`sovetromantica.com` → `SovetRomanticaParser`; `my.mail.ru` → `MailRuParser`;
`www.myvi.top`/`myvi.top` → `MyviParser`; `ok.ru`/`m.ok.ru` → `OKParser`;
`vkvideo.ru`/`vk.com` → `VKVideoParser`; `secvideo1.online`/`csst.online`/`sstrge.online` →
`AllvideoParser`; иначе `throw Exception("Invalid url")` (`analysis/strings.txt:168678`).
У `Parser` два словаря качеств (`I1IlIlIll`, `II111lII1I`), `referer` и `cookie`; HTTP-хелпер —
OkHttp, таймаут 20 с, UA по умолчанию `Mozilla/5.0 (Windows NT 10.0; Win64; x64) … Chrome/86.0.4240.198`.

### 1.2. `config/toggles` — серверные переключатели плееров
`ConfigApi.toggles(versionCode, …, token)` (`ConfigRepository`, `ConstantNetFetcher`) вызывается на
старте. Без `version_code` — `200` с пустым телом; с параметром — полный JSON (проверено анонимно
24.11.2026): `GET https://api-s.anixsekai.com/config/toggles?version_code=26111702`.
Живые значения важных ключей: `kodikVideoLinksUrl` = `https://kodikplayer.com/get-video-info`,
`kodikIframeAd` = `true`, `kodikAdIframeUrl` = `https://anixmirai.com/iframe/ad?url=`,
`iframeEmbedUrl` = `https://anixmirai.com/iframe?url=`, `sibnetRandUserAgent` = `true`,
`sibnetUserAgent` — мобильный UA, **случайный на каждый запрос**, `impMessageText` — «Сейчас
наблюдаются временные проблемы с работой видео из источника Kodik на территории РФ.».
В dex это `TogglesResponse` (`analysis/strings.txt:172298`): `iframeEmbedUrl`, `kodikVideoLinksUrl`,
`kodikAdIframeUrl`, `kodikIframeAd`, `sibnetUserAgent`, `sibnetRandUserAgent`
(`getIframeEmbedUrl` — `:196603`, `getKodikVideoLinksUrl` — `:196735`, `getKodikAdIframeUrl` —
`:196733`, `getSibnetUserAgent` — `:197628`, `getSibnetRandUserAgent` — `:197627`). Ожидаемая версия
клиента — `26111702` (`ConfigNetFetcher`; тот же код в ad-прокси: `&v=26111702`).

## 2. Kodik
**URL от API.** `iframe: true`:
`https://kodikplayer.com/seria/175268/48eeb2a7bd81c9c3139634faa2b793db/720p?d=2026112404&s=…&ip=178.208.227.243`
(путь `seria/{kodikId}/{hash}/{quality}`). Хосты — `kodikplayer.com`, `kodik.cc`, `kodik.info`,
`aniqit.com` (`analysis/strings.txt:199447-199455`; `KODIK_URL` — `:168800`).

**WebView через iframe-прокси.** `EpisodesFragment.onWebPlayer(url, iframe)` кладёт в интент
`URL_VALUE`, `IFRAME`, `ORIENTATION_LANDSCAPE` и открывает `WebPlayerActivity`; при `IFRAME=true`
активити делает `webView.loadUrl(iframeEmbedUrl + URLEncoder.encode(kodikUrl, "UTF-8"))`, то есть
`https://anixmirai.com/iframe?url=https%3A%2F%2Fkodikplayer.com%2F…`. Эта страница (проверено:
`200 text/html`, «Веб-плеер») содержит белый список хостов (`kodik.info`, `aniqit.com`, `anivod.com`,
`devon.allohastream.com`, `kodikplayer.com`, `sovetromantica.com`, `vkvideo.ru`, `anixart.libria.fun`)
и `showPlayer()`, создающий `<iframe src="<переданный url>">`. Referer запроса к Kodik —
`https://anixmirai.com/`, а не `file://`/`anixart.app`; в этом смысл прокси. При `KODIK_DOWN=true`
прокси показывает заглушку «Временные неполадки», а `studiomir.club` помечает «Не поддерживается».

**Прямое открытие не работает.** `GET` подписанной ссылки Kodik отдаёт `500`
(`Извините, но данной страницы не существует` / `Error code: ds`) — проверено с Referer
`anixart.app`, `anixart-app.com`, `kodikplayer.com` и без него. Поэтому iOS нельзя грузить
Kodik-страницу напрямую — только через прокси `iframeEmbedUrl` (или свой серверный редирект).

**Реклама.** В конфиге `kodikIframeAd: true`, `kodikAdIframeUrl`. `KodikAdActivity` добавляет JS-мост
`KodikInterface` и грузит `kodikAdIframeUrl + URLEncoder.encode(kodikUrl) + "&v=26111702"`;
ad-страница выставляет `uid=J52WjR&only_a=true&advert_debug=true`, ждёт `kodik_player_advert_ended`
(или `advertEnded()`), таймаут 30 с; на Android 5/6 реклама отключается; ошибка — `"Kodik ad
initialization error"` (`analysis/strings.txt:168824`). В страницу внедряется скрипт, который ищет
`<video>` в iframe до 3 уровней и сообщает через `KodikInterface.adVideoStarted` /
`postMessage({key:'anixart_ad_video_started'})` (`:161290`).

**KodikParser (нативный fallback).** Для `iframe: false` на хостах Kodik работает `KodikParser`
(`analysis/strings.txt:172396`); его строки обфусцированы LSParanoid (класс `LllI/IIl1/…`), точные
шаблоны не читаются как текст. По байткоду: парсер забирает HTML страницы Kodik (30 с), регулярками
вытаскивает несколько ссылок, чистит их (`Il1IIIIl1`, `l1l11lllI`) и складывает в словарь качеств; при
пустом ответе шлёт событие в AppMetrica. Серверный `kodikVideoLinksUrl`, настройки
`selected_kodik_video_quality` / `KODIK_VIDEO_QUALITY_TAG` (`:168801`, `:203513`) и диалог
`KodikVideoQualityDialogFragment` (`:188417`) относятся к этому нативному пути.

**Ошибки.** 500 при прямом открытии; заглушки прокси («Не поддерживается», «Временные неполадки»);
ошибка WebView (main-frame HTTP ≥ 400 / SSL) — своя страница с кнопкой перезагрузки; ошибка
инициализации рекламы. `WebPlayerActivity` блокирует по `adblock.txt` (`analysis/strings.txt:191903`)
запросы только для хостов Sibnet/MailRu/Myvi/Allvideo — Kodik не трогает.

**iOS.** WKWebView на `iframeEmbedUrl + urlencoded(kodikURL)`; реклама — отдельный WKWebView на
`kodikAdIframeUrl` с JS-мостом `{adVideoStarted, advertEnded}` (таймаут 30 с). Referer вручную не
подставлять — это делает прокси.

## 3. Sibnet
**URL от API.** `iframe: false`,
`https://video.sibnet.ru/shell.php?videoid=2665039&d=2026112404&s=…&ip=178.208.227.243`.

**Нативный парсер** `SibnetParser.l11IlIIl1l`:

1. GET `shell.php` с UA из настроек (`Parser.lIl11Il11()` — строка `sibnetUserAgent` из
   `config/toggles`; при `sibnetRandUserAgent: true` сервер каждый раз отдаёт новый мобильный UA),
   без Referer, таймаут 14 с.
2. HTML-регулярка `src: "(.*?)"` вытаскивает путь видео; к нему приклеивается
   `https://video.sibnet.ru` (`analysis/strings.txt:198334`).
3. GET этого URL с `Referer: <shell.php URL>` и `followRedirects=false`, читается `Location`; затем
   второй запрос/резолв, из результата убирается `:443`.
4. Итог — в качества под ключом `Default`.

**Заголовки.** UA обязателен (серверный, ротируемый); `Referer` — только на резолве редиректа и равен
подписанному `shell.php`; Origin не используется.

**Ошибки.** На нашей машине `shell.php` отдал `403 Forbidden` / `Request forbidden by administrative
rules.` для всех проверенных UA (десктопный Chrome, Android Chrome, Yandex, python) — Sibnet режет по
IP/UA. Если регулярка `src:` не сработала — словарь пуст, показывается экран ошибки парсинга.

**iOS.** Повторить цепочку: `shell.php` с UA из `config/toggles` → regex `src:` → резолв 302 с
`Referer: shell.php` → готовый MP4/HLS в AVPlayer. UA обязателен (без него 403) — держите
server-provided UA и обновляйте его из `config/toggles`.

## 4. AniLibria / Libria / Liberty
**URL от API.** `iframe: false`,
`https://anixart.libria.fun/public/iframe.php?id=1243&ep=1&d=2026112404&s=…&ip=…`. Хосты
`anixart.libria.fun`, `anilibria.top`, `anilibria.tv`, `new.anilib.one` (`analysis/strings.txt:192172`,
`:192173`, `:192185`).

**Нативный парсер** `AniLibriaParser.l11IlIIl1l`:

1. Регулярка `id=(\d+)&ep=(\d+)` достаёт id релиза AniLibria и номер серии.
2. GET `https://anilibria.top/api/v1/anime/releases/{id}` (`analysis/strings.txt:198306`), таймаут 30 с,
   UA серверный.
3. Jackson-модель `Response{episodes[]}` (`Episode{ordinal, hls_480, hls_720, hls_1080, duration}` —
   `:198259-198261`); находится `ordinal == ep`, непустые ссылки — `1080p`/`720p`/`480p`.
4. Фолбэк (если качеств нет): GET самого signed `iframe.php`, разбор Playerjs регулярками
   `"s".*?"file":"(.*?)"` и `\[([0-9]*p)](.*?)(,|$)`, после `replace("\\/","/")` — ссылки
   360p/480p/720p/1080p в словарь.

**Проверка живьём (24.11.2026).** `GET https://anilibria.top/api/v1/anime/releases/1243` →
`episodes[0] = {ordinal:1, hls_480:"https://cache-rfn.libria.fun/…/480/…m3u8?countryIso=RU&isAuthorized=0&isWithVideoAds=1…",
hls_720:"…", hls_1080:null}`. Signed `iframe.php` → `200 text/html` со страницей «AniLibria - так звучит
аниме!» и `new Playerjs({default_quality:"720p", file:[{"id":"s1",…,"file":"[480p]https:\/\/cache.libria.fun\/…m3u8?clientIp=…&isWithAds=1&countryIso=RU&isAuthorized=1,[720p]…"}]})`.
Ссылки `cache.libria.fun/…m3u8` → `200` и валидный HLS (`#EXTM3U`, TS-сегменты).

**Параметры.** Авторизация не нужна (подпись в URL); в m3u8 уже вшиты `clientIp`, `countryIso=RU`,
`isAuthorized`, `isWithAds` — URL брать ровно из ответа, query не «чистить».

**Ошибки.** Нет `hls_*` и не распарсился фолбэк → пустой словарь → отладочная строка
`Return 1#…#2#…#5#` (`analysis/strings.txt:188278`) уходит в экран ошибки; гео-ограничения отдаёт CDN
Libria (параметр `countryIso`).

**iOS.** Два валидных варианта: (а) WKWebView на signed `iframe.php` — работает как есть (Playerjs +
реклама VAST); (б) нативно: id/эпизод из URL → `anilibria.top/api/v1/...` → AVPlayer HLS (контроль
качества, но нужен доступ к `cache*.libria.fun` из страны устройства).

## 5. RuTube
**URL от API.** `iframe: false`; URL обычно `https://rutube.ru/video/<32hex>/`, `.../play/embed/<32hex>`,
`.../shorts/<32hex>` или `.../video/private/<32hex>?p=<key>` — четыре шаблона, которые ищет парсер
(`analysis/strings.txt:203281-203284`; `RUTUBE_URL` — `:188079`).

**Нативный парсер** `RuTubeParser`:

1. Регулярками достаёт 32-hex id и (для private) параметр `p`.
2. GET `https://rutube.ru/api/play/options/{id}/?no_404=true&referer&pver=v2` (`:198328`) с
   `Referer: https://rutube.ru/` (`:198327`), UA из настроек, таймаут 10 с.
3. JSON `PlayOptions{detail, video_balancer, live_streams}`: `detail.type == "blocking_rule"` —
   регион-лок; непустой `live_streams.hls` — «прямой эфир не поддерживается»; иначе берётся
   `video_balancer.m3u8` и запрашивается с тем же `Referer`.
4. Master-m3u8: `#EXT-X-STREAM-INF:` + `RESOLUTION=(\d+)x(\d+)` + `BANDWIDTH=(\d+)`, следующая
   строка — URL варианта; качество по `max(width,height)`: ≥3840 → `2160p`, ≥2560 → `1440p`,
   ≥1920 → `1080p`, ≥1280 → `720p`, ≥854 → `480p`, ≥640 → `360p`; сортировка по убыванию.

**Проверка живьём.** `GET https://rutube.ru/api/play/options/c62caf58bd71d1641e88cdc97d6bc6b9/?no_404=true&referer&pver=v2`
с `Referer: https://rutube.ru/` → `200`, JSON с `video_balancer.m3u8` (master на
`https://bl.rutube.ru/route/…m3u8?guids=…`) и `live_streams: {}`; master-m3u8 → `200` и строки
`#EXT-X-STREAM-INF:…RESOLUTION=1920x1080`, `1280x720`, … с сегментами на `rtbcdn.ru`/`river-1.rutube.ru`
(ключа `detail` в живом ответе нет).

**Ошибки** (`analysis/strings.txt:188310-188317`): `Video is unavailable or does not exist`,
`Empty response from API`, `Failed to extract video ID from URL`, `Live streams are not supported`,
`Video is region-locked`, `M3U8 URL not found`, `Empty M3U8 content`, `Error during parsing`.
Сигнал регион-лока — `detail.type == "blocking_rule"`.

**iOS.** Запрос options с `Referer: https://rutube.ru/` (иначе 403/404), выбор `video_balancer.m3u8`,
AVPlayer по master-m3u8 (сам разберёт варианты) или свой разбор, как выше. За пределами RU сервер
вернёт `blocking_rule` — показывать понятную ошибку.

## 6. AnixPlayer / StudioMir
**URL от API.** Источник приходит ссылкой на `studiomir.club`, из которой парсер достаёт `ani` и `ep`;
хосты `studiomir.club`/`api.studiomir.club` (`:205225`). Живых примеров таких URL найти не удалось
(в выборке ~50 случайных релизов источника AnixPlayer не было).

**Нативный парсер** `StudioMirParser`:

1. Регулярки `[?&]ani=(\d+)` и `[&?]ep=(\d+)`.
2. GET `https://api.studiomir.club/api?ani={ani}&apikey=80b2d3e9c4ff27eb2e924c4d38f7daec`
   (`analysis/strings.txt:198310`; apikey — хардкод в dex), таймаут 14 с, UA серверный.
3. Response — **JSON-массив**; берётся `[0].players.tsm[]` (`TsmEpisode{episode,type,url,hls{2160p,1080p,720p}}`);
   серия выбирается по `episode == ep` с приоритетом `type == "TV"`, затем `"TR"`, иначе последняя;
   качества из `hls` (`2160p`/`1080p`/`720p`), если пусто — `url` как `Default`.

**Проверка живьём.** `GET https://api.studiomir.club/api?ani=1&apikey=80b2d3e9c4ff27eb2e924c4d38f7daec`
→ `200 application/json`, массив из 1 элемента, `players: {tsm, sibnet, vk}`,
`tsm[0] = {episode:1, type:"TR", url:"https://hokage-alt.studiomir.club/animes/vids/encoded/1/30001/hls/…m3u8",
hls:{"2160p":"", "1080p":"https://…m3u8", "720p":""}}`.

**Важно:** iframe-прокси `anixmirai.com/iframe` помечает `studiomir.club` как `unsupported` (заглушка
«Доступ к воспроизведению… только во встроенном и сторонних плеерах и только в версии 9.0 BETA 6 или
выше»), поэтому этот источник нельзя открывать в WKWebView — только нативно по API.

**AnixPlayer как отдельное приложение.** Пакет `com.swiftsoft.anixart.player`; в приложении есть
`ChoosePlayerDialogFragment` → `onAnixPlayerNotInstalled` / `onAnixPlayerDownloadUrlResolved`, скачивание
APK (`AnixPlayer.apk`, `analysis/strings.txt:165494`, `:165285`) по ссылкам из `config/anixplayer`
(живой ответ: `https://anixart-app.com/dl/anixplayer-{arm64-v8a,armeabi-v7a,universal,x86_64,x86}.apk`);
intent внешнему плееру несёт `video_list` (+`name/info/thumbnail`), `headers` (Referer/Cookie), `title`,
`playlist_qualities`, `selected_quality`, `playlist_positions`, `host_package_name`,
`host_version_name="11 BETA 3"` — для iOS не нужна.

**iOS.** Повторить API-запрос (apikey хардкод), выбрать серию, взять m3u8 из `hls`/`url`, играть
AVPlayer HLS. Заголовки не требуются (кроме UA, который оригинал всё равно подставляет).

## 7. YouTube
**В конвейере серий YouTube нет:** хоста `youtube.com`/`youtu.be` нет в таблице парсеров `Parser`,
`episode/target` в проверенных релизах YouTube-ссылок не отдавал, а `EmbedActivity` из
episodes-презентера не вызывается. Это экран встроенного видео для статей/трейлеров; на iOS его надо
повторять только если такие видео нужны.

**Как реализован YouTube (`EmbedActivity` + `assets/player_youtube.html`):**

* `onCreate` регистрирует JS-мост `window.YoutubeProxy` (`analysis/strings.txt:190818`) и по regex
  `(?:https?://)?(?:www\.)?(?:(?:youtu\.be/)|(?:youtube\.com)/(?:v/|u/\w/|embed/|watch))(?:(?:\?v=)?([^#&?=]*))?((?:[?&]\w*=\w*)*)`
  вытаскивает `videoId`; из query берёт `start` и `end` (секунды). В dex есть и упрощённый regex
  embed-ссылок (`:198338`).
* `handleYoutubeService`: читает asset `player_youtube.html` (`:202142`), `String.format(html, videoId,
  start, end)` и `webView.loadDataWithBaseURL("https://youtube.com", html, "text/html", "UTF-8",
  "https://youtube.com")` (baseURL/Origin — `:198340`).
* `player_youtube.html` — обёртка над YouTube IFrame API (`https://www.youtube.com/iframe_api`):
  `new YT.Player("player", {videoId:"%1$s", playerVars:{start:%2$d, end:%3$d, rel:1, showinfo:0,
  modestbranding:0, iv_load_policy:3, autohide:1, autoplay:1, cc_load_policy:1, playsinline:1,
  controls:0}})`; события `onReady`/`onError`/`onStateChange`, методы `playVideo`, `pauseVideo`,
  `seekTo`, `setPlaybackSpeed`, `pollPosition`; всё — через `window.YoutubeProxy`:
  `onPlayerLoaded`, `onPlayerError`, `onPlayerStateChange`, `onPlayerNotifyDuration`,
  `onPlayerNotifyCurrentPosition`, `onPlayerNotifyBufferedPosition` (`:201518-201523`).
* Ошибка в лог — `[YOUTUBE ERROR] <code>`. Есть режим VK (`handleVkService`) с `player_default.html` (`:202136`).

**iOS.** Повторяйте `player_youtube.html`: WKWebView с `allowsInlineMediaPlayback`, baseURL
`https://youtube.com` (Origin/Referer), YT IFrame API и `WKScriptMessageHandler` вместо
`YoutubeProxy`; `start`/`end` из query. Если сервер когда-нибудь начнёт отдавать YouTube-ссылки в
`episode/target`, текущий Android-клиент их не разберёт — нужна отдельная ветка.

## 8. Остальные парсеры и внешние плееры
`my.mail.ru` → `MailRuParser` (GET `https://my.mail.ru/+/video/meta/…`); `ok.ru` → `OKParser`;
`vkvideo.ru`/`vk.com` → `VKVideoParser` (VK API с анонимным токеном); `secvideo1.online`/`csst.online`/
`sstrge.online` → `AllvideoParser`; `www.myvi.top` → `MyviParser`; `TorlookParser` — поиск по торрентам.
`sovetromantica.com` → `SovetRomanticaParser`: `iframe: true`
(`https://sovetromantica.com/embed/episode_…`, регулярка `(.*/).*.m3u8`), но сервер помечает источник
«Sovet (не работает)». Все они складывают ссылки в тот же словарь качеств и играются `SwiftPlayerActivity`.
Внешние плееры (`ChoosePlayerDialogFragment`, `ChooseThirdPartyPlayerDialogFragment`): SwiftPlayer,
AnixPlayer (`com.swiftsoft.anixart.player`), VLC (`org.videolan.vlc`), MX Player
(`com.mxtech.videoplayer.pro`/`.ad`); intent `ACTION_VIEW` с `video/*`, `headers` = `Referer` + `Cookie`,
`title`. Для iOS проще всегда играть внутри (`AVPlayer`/`UIDocumentInteractionController`).

## 9. Нативный игрок SwiftPlayer (общие требования)
`SwiftPlayerActivity` — AndroidX Media3 ExoPlayer (`HlsMediaSource`, `DashMediaSource`,
`ProgressiveMediaSource` по типу контента), MediaSession, жесты, поворот, PiP, эффект Anime4K.
В интент передаются (`EpisodesFragment.onSwiftPlayer`): `RELEASE_VALUE`, `EPISODES_VALUE`,
`INDEX_VALUE`, `SORT_VALUE`, `PLAYBACK_POSITION_VALUE`, `COOKIE`, `REFERER_VALUE`, `URL_VALUE`
(выбранное качество) и `QUALITY_*_VALUE` (`DEFAULT/LOW/SD/HD/FHD/QHD/UHD`); `REFERER_VALUE` /
`REFERER_STRING_VALUE` — просто имена extras (`analysis/strings.txt:187974-187975`), не заголовки.

* Каждый медиазапрос проходит OkHttp-интерсептор: `User-Agent` — жёстко
  `Mozilla/5.0 (Windows NT 10.0; Win64; x64) … Chrome/96.0.4664.45 Safari/537.36`; `Referer` —
  `REFERER_VALUE`, если пусто — `URL_VALUE`; `Cookie` — `COOKIE` (если непусто).
* Ошибки: Media3 `PlaybackException` (в т.ч. коды `2000`, `2004`, `4003`); в AppMetrica уходит
  `stream_type` (`Progressive`/`HLS`/`DASH` через `Util.inferContentType`), `decoder` из
  `Decoder (?:failed|init failed): (\S+)`, DNS-fallback-флаги; на экране — сообщение и кнопки
  повтора/выбора качества.
* Выбор качества: диалог по списку или настройки `selected_*_video_quality`; для Kodik — ветка с
  логом `no ads => remove high and ultra high qualities =>` (`analysis/strings.txt:200784`).

## 10. Выводы для iOS-клиента
1. **Источник истины — URL и флаг `iframe`**, а не `source.name`.
2. **Kodik и подобные `iframe: true`** — WKWebView на `iframeEmbedUrl + encode(url)` из
   `config/toggles` (живой префикс `https://anixmirai.com/iframe?url=`). Это единственный надёжный
   путь: сам Kodik на прямой запрос отвечает 500, а прокси подставляет Referer. Реклама — отдельный
   WKWebView на `kodikAdIframeUrl` с мостом `{adVideoStarted, advertEnded}` (таймаут 30 с).
3. **Остальные (`iframe: false`)** — нативный AVPlayer по ссылкам, которые достал парсер,
   повторяющий логику §3–§6 (Sibnet regex/redirect, Libria API, RuTube options, StudioMir API);
   media-запросы — с `Referer` из парсера, `Cookie` при наличии, UA из `config/toggles` (Sibnet)
   или десктопный Chrome.
4. **`config/toggles`** забирать на старте с `version_code=26111702` (без параметра — пустой ответ);
   хранить `iframeEmbedUrl`, `kodikVideoLinksUrl`, `kodikAdIframeUrl`, `kodikIframeAd`,
   `sibnetUserAgent`, `sibnetRandUserAgent`, `impMessageText`.
5. **Заголовки в AVPlayer.** Штатно AVPlayer не даёт менять `User-Agent`/`Referer` у HLS: понадобится
   `AVURLAsset` c `AVURLAssetHTTPHeaderFieldsKey` (непубличный, риск App Review) либо
   `AVAssetResourceLoaderDelegate`/локальный HTTP-прокси (перенос логики OkHttp-интерсептора из §9).
6. **Ошибки как в оригинале**: WebView — экран по `onReceivedHttpError`/`onReceivedError` (main frame);
   нативный — текст Media3-ошибки и кнопка повтора; регион-лок RuTube — отдельное сообщение.
7. **`episode/watch`** после старта (без токена 401); `episode/target` запрашивать перед запуском.

## 11. Что осталось неизвестным / не проверено
* Точные шаблоны `KodikParser` не расшифрованы (LSParanoid, расшифровка в рантайме): неизвестно, как
  он строит запрос к `kodikVideoLinksUrl` и в каком формате забирает ссылки; в живых ответах Kodik
  приходит с `iframe: true`, поэтому нативный путь на практике не наблюдался. `KODIK_URL` встречается
  в dex только как идентификатор (`analysis/strings.txt:168800`), значение в коде не найдено;
  фактический URL берётся из `config/toggles.kodikVideoLinksUrl`. Значение `REFERER_STRING_VALUE`
  (в отличие от `REFERER_VALUE`) не расшифровано; по коду это extra, а не заголовок. Почему Kodik
  отвечает 500 (`Error code: ds`) — не установлено; на iOS неважно, пока используется прокси.
* Реальные примеры **RuTube**, **AnixPlayer/StudioMir** и **YouTube** в `episode/target` не найдены
  (выборка ~50 случайных релизов + release 1/5/92/1562/20306): поведение описано по dex; живьём
  проверены только API парсеров. Sibnet с нашей машины отдаёт 403 на все UA — работа парсера на
  устройстве не подтверждена.
* `config/urls` анонимно возвращает `200` с пустым телом (как и `config/toggles` без `version_code`);
  форма ответа неизвестна. Почему у release 5 (Sibnet) нет серий (`code:1`) — вопрос к серверу.

## 12. Что проверить на устройстве
1. **Kodik**: открывается ли `https://anixmirai.com/iframe?url=<signed>` в WKWebView на iOS, играет
   ли iframe-Kodik (autoplay, EME/DRM), работают ли поворот/полный экран/PiP, не блокирует ли Kodik
   ATS/ITP; отдельно — что прямой `GET` signed URL из iOS даёт 500 и прокси обязателен.
2. **Реклама Kodik**: `kodikAdIframeUrl + encode(url) + &v=26111702` — приходят ли `adVideoStarted` /
   `kodik_player_advert_ended`, срабатывает ли 30-секундный таймаут.
3. **Sibnet**: работает ли `shell.php` с UA из `config/toggles` с iOS (у нас с сервера — 403),
   резолвится ли 302 и играет ли AVPlayer итоговый MP4/HLS с `Referer`.
4. **Libria**: доступен ли `anilibria.top/api/v1/...` с iOS, играет ли AVPlayer
   `cache.libria.fun/…m3u8?countryIso=…&isAuthorized=…`; что показывает signed `iframe.php` в WKWebView.
5. **RuTube**: `play/options` с `Referer: https://rutube.ru/` с iOS, воспроизведение
   `bl.rutube.ru/route/…m3u8`, поведение вне РФ (`blocking_rule`), private-видео с `?p=`.
6. **AnixPlayer/StudioMir**: найти реальный релиз с таким источником (в выборке ~50 не было),
   проверить формат ссылки (`ani`/`ep`), актуальность apikey и структуру `players.tsm`.
7. **YouTube**: есть ли релизы с YouTube-ссылкой в `episode/target`; если да — нужен отдельный путь.
8. **`episode/target` и `config/toggles`**: срок жизни `d`/`s`, привязка к `ip` при смене сети
   (Wi-Fi ↔ LTE); полный JSON toggles с iOS без токена при `version_code=26111702` (без параметра —
   пустой 200), нужен ли фолбэк на захардкоженные значения.
9. **Качества и ошибки**: непустые наборы для всех плееров, выбор качества, ветка Kodik «no ads»;
   экран типа `no_connection.html` (`analysis/strings.txt:195418`) и заглушки прокси — тексты 1:1.
10. **Отметка просмотра**: `episode/watch` после старта (с токеном) — прогресс/история как в Android.

## Kodik: прямой резолв в HLS (решено 24.11.2026)

Раньше Kodik открывался только через WebView-прокси `anixmirai.com/iframe`
и показывал «Error code: ds»: API отдаёт подписанную ссылку
`kodikplayer.com/seria/{id}/{hash}/{quality}?d=…&s=…&ip=…`, и подпись не принимается.

Решение (подсмотрено в клиенте [Anixapp-Community/anixapp](https://github.com/Anixapp-Community/anixapp),
`src/native/kodik-direct.ts`): подпись не нужна.

1. Берём ссылку Kodik из `episode/target/{release}/{source}/{pos}` и **отбрасываем query**
   (остаётся `https://kodikplayer.com/seria/{id}/{hash}/{quality}`).
2. `GET https://kodikplayer.com/ftor?type=seria&hash={hash}&id={id}` с `Referer` на страницу
   и браузерным User-Agent → JSON `{"links": {"360": [{"src": …}], "480": …, "720": …}}`.
3. `src` декодируется: ROT+18 по буквам внутри регистра → Base64 → UTF-8. Для mp4 на
   `solodcdn/kodik-storage` дописывается `:hls:manifest.m3u8`.
4. Получаем прямые HLS-ссылки вида
   `https://cloud2.solodcdn.com/.../720.mp4:hls:manifest.m3u8` → **AVPlayer**, без WebView и прокси.

Проверено живыми запросами: m3u8 — 200 (`#EXTM3U`), первый сегмент — 206, `video/MP2T`, 1,1 МБ.
Клиент: `Anixart/Features/Player/KodikDirectResolver.swift`, тесты — `KodikDirectTests` (14 проверок).

Fallback: если `ftor` не ответил или структура изменилась — прежний web-плеер через прокси
остаётся как запасной путь; автоподбор источника тоже на месте.

## Фактическая проверка (24.11.2026)

| Провайдер | Статус | Доказательство |
|---|---|---|
| AniLibria | ✅ играет | CI-скриншот `09-player-native.png`: кадр серии в AVPlayer |
| AnixPlayer/StudioMir | ✅ играет | CI-скриншот `10-player-anixplayer.png`: кадр видео, HLS со studiomir |
| Kodik | ✅ играет нативно | прямой резолв `kodikplayer.com/ftor` → HLS → AVPlayer; m3u8 200, сегмент 206; скриншот `08-player.png` |
| VK-видео (трейлеры/опенинги) | ✅ embed открывается | скриншот `12-video-vk.png` |
| YouTube-видео | ⚠️ embed открывается, видео ограничено регионом | скриншот `11-video-youtube.png`: плеер YouTube загрузился, конкретный ролик вернул «This video is unavailable (152-4)» — решение самого YouTube, не наш код |
| Sibnet | ⚠️ сервер закрыт | `episode/target` отдаёт `shell.php`-ссылку, но `video.sibnet.ru` отвечает **403** с любых наших IP; на iOS-устройстве проверить отдельно |
| RuTube | ⚠️ контента нет | в 100 просмотренных релизах RuTube нет ни в источниках серий, ни в видео релиза (только YouTube/ВКонтакте/Sibnet). Резолвер готов, проверить не на чем |

### Найденный баг, из-за которого «был только Kodik»

Сервер отдаёт `sources[].type` в двух формах: объектом озвучки и **числом** (`"type": 2`).
Строгая модель `EpisodeType` падала на числе, из-за чего **вся озвучка** не декодировалась
и пропадала из UI — оставались только озвучки с единственным источником Kodik.
Исправлено терпимым декодером `EpisodeType` (`init(from:)` принимает и объект, и `Int`),
регрессионные тесты — `EpisodeSourceDecodingTests` (5 проверок).

## Sibnet в iOS-клиенте: нативный плеер (24.11.2026)

`SibnetResolver` + `EpisodePlaybackService` дают нативное воспроизведение Sibnet:
`episode/target` → подписанный `shell.php` → путь MP4 → доследование 3xx → `.hls(URL)`
в `AVPlayer` (WebView остаётся только запасным путём).

Алгоритм повторяет рабочий reference-клиент `Anixapp-Community/anixapp`
(`electron/lib/direct-video-link.js`):

1. `GET shell.php` с браузерными заголовками (`Referer: https://sibnet.ru/`, полный
   `Accept`, `Accept-Language: ru-RU…`) и мобильным Safari UA; при `403` — повтор
   с Android WebView UA.
2. HTML «видео удалено / не найдено / access denied» → `PlaybackError.playbackUnavailable`.
3. Путь видео — 6 регулярок в приоритете: `player.src([{ src: "/…"`, `src: "/v/….mp4"`,
   `src: "/shell.php?…"`, общий `src: "/…"`, одинарные кавычки, `file: "/shell.php…"`.
   Относительные ссылки достраиваются, `&amp;` и `\/` разворачиваются.
4. `GET` кандидата с `Referer: <shell.php>`, `Range: bytes=0-0`, ≤5 прыжков по
   `Location`; готовый ответ — `200/206` с `Content-Type` `video/`, `octet-stream`,
   `mp4` или `mpegurl`.
5. **Заголовки для AVPlayer**: Sibnet-CDN проверяет источник, а публичного API
   заголовков у `AVURLAsset` нет — поэтому `PlaybackTarget.httpHeaders` уходят в
   `NativePlayerView` и применяются через `AVURLAssetHTTPHeaderFieldsKey`
   (`Referer: https://video.sibnet.ru/`, браузерный `User-Agent`).

Непроверенное (только устройство): живой HTML `shell.php`/цепочка `Location` и то,
какие именно заголовки требует Sibnet-CDN, — из нашего региона `video.sibnet.ru`
отвечает `403` на любой запрос. Тесты — `SibnetResolverTests` (9, офлайн).
