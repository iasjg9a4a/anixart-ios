import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif

/// Прямая ссылка для нативного плеера из HTML-вставки Sibnet.
///
/// ## Откуда взят алгоритм
///
/// iOS-порт повторяет не dex-парсер Android (там одна регулярка `src: "(.*?)"`),
/// а рабочий reference-клиент `Anixapp-Community/anixapp`
/// (`electron/lib/direct-video-link.js`, функции `getSibnetDirectLink` /
/// `extractSibnetSrcPath` / `followSibnetLocation` / `isSibnetUnavailableHtml`):
/// он не показывает `shell.php` в WebView, а вытаскивает из HTML путь MP4,
/// достраивает URL и дослеживает 3xx до готового файла.
///
/// ## Шаги
///
/// 1. GET `shell.php` с браузерным/мобильным `User-Agent`, `Referer: https://sibnet.ru/`
///    (корень сайта, **не** `video.sibnet.ru`), `Accept: text/html,application/xhtml+xml,
///    application/xml;q=0.9,*/*;q=0.8` и `Accept-Language: ru-RU,ru;q=0.9,en-US;q=0.8`.
///    UA из `config/toggles` (`sibnetUserAgent`), если он передан, идёт первым.
///    При `403` — повтор с Android WebView UA; если снова `403` — ошибка
///    (верхний уровень уйдёт в web-плеер).
/// 2. HTML-страница «нет видео» («видео удалено», «видео не найдено», «видео не
///    существует», «удалено пользователем», `video deleted`, `video not found`,
///    `access denied`) — это `PlaybackError.playbackUnavailable`, а не таймаут
///    и не «нет ссылки»: смотреть нечего, а не «Sibnet не разобрали».
/// 3. Путь видео из HTML ищется по списку регулярок в порядке приоритета:
///    `player.src([{ src: "/..." ...`, `src: "/v/....mp4"`, `src: "/shell.php?..."`,
///    `src: "/..."`, `src: '/...'`, `file: "/shell.php..."`. Путь может быть
///    относительным — его достраивает `absoluteURL` (абсолютный URL, `//host/...`
///    и путь от `shell.php`; HTML-сущности `&amp;` и JSON-экранирование `\/`
///    разворачиваются).
/// 4. GET кандидата с `Referer: <shell.php>`, тем же UA, `Accept: */*` и
///    `Range: bytes=0-0` (файл не качаем). До 5 прыжков по `Location`
///    (абсолютный или относительный; редирект на HTML-страницу отклоняется).
///    Готовая ссылка — ответ `200`/`206` с `Content-Type`, содержащим `video/`,
///    `octet-stream`, `mp4` или `mpegurl`. HTML-страница вместо видео — ошибка;
///    если в ней маркеры «нет видео» — `playbackUnavailable`.
/// 5. Готовая ссылка уходит в `PlaybackTarget(kind: .hls(...))`: по контракту
///    `PlaybackKind.hls` — это любой прямой поток, включая MP4 (см. комментарий
///    в `PlaybackTarget.swift`). Referer экрана — корень видеохоста, `variants: nil`
///    (качество у Sibnet одно — `Default`, как в Android-парсере).
///
/// ## Что подтверждено
///
/// * Живой API 24.11.2026: у Sibnet-источника release 1562 (`episode/1562/1/1`)
///   позиции серий начинаются с **0** («1 серия» = `position: 0`), а
///   `episode/target/1562/1/0` отдаёт подписанный `shell.php` (`d`/`s`/`ip`).
///   Вызывающий код берёт позицию из `episodes[]`, поэтому 0-базовая нумерация
///   ничего не ломает; `episode/target/.../1` — это реально «2 серия», и повторный
///   запрос позиции 0 был бы ошибкой.
/// * `video.sibnet.ru` с нашей сети отвечает `403` / «Request forbidden by
///   administrative rules» на любой URL и любой UA — региональная блокировка;
///   корень `sibnet.ru` при этом отвечает `200`. Живой HTML `shell.php` не
///   проверялся (см. `docs/PLAYERS.md` §12).
/// * Вид HTML (`player.src([{ src: "/v/....mp4" ... }])`), приоритет регулярок,
///   заголовки страницы и поведение редиректов — из reference-клиента
///   (`electron/lib/direct-video-link.js`).
///
/// ## Что НЕ проверено — только на устройстве
///
/// * Живой HTML `shell.php` и реальная цепочка `Location` на MP4.
/// * Что AVPlayer играет итоговый MP4 с `Referer: https://video.sibnet.ru/`.
/// * `config/toggles.sibnetUserAgent` в iOS ещё не перенесён, поэтому UA по
///   умолчанию — захардкоженный мобильный Safari; когда появится
///   `ConfigRepository`, серверный UA можно передать в перегрузку
///   `resolve(url:title:userAgent:)`.
enum SibnetResolver {

    // MARK: - Константы

    /// Имя источника для UI и логов (`PlaybackTarget.providerName`).
    static let providerName = "Sibnet"

    /// Referer, который кладётся в `PlaybackTarget`: корень видеохоста, как в контракте.
    static let referer: URL? = URL(string: "https://video.sibnet.ru/")

    /// Браузерный `User-Agent` reference-клиента (`BROWSER_UA` в
    /// `electron/lib/direct-video-link.js`) — им он скачивает готовый MP4.
    static let desktopChromeUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /// HTTP-заголовки для запросов нативного плеера к готовому MP4.
    ///
    /// Reference-клиент ставит `Referer` в медиазапросах
    /// (`src/views/Watch/core/hls-media-context.ts`, `hostNeedsEmbedReferer`
    /// включает `sibnet`), а скачивание ходит с браузерным `User-Agent`.
    /// `AVPlayer` публично не умеет менять заголовки, поэтому они уходят в
    /// `PlaybackTarget.httpHeaders` и применяются в `NativePlayerView` через
    /// `AVURLAssetHTTPHeaderFieldsKey` — без них Sibnet-CDN может ответить
    /// 403 или пустым потоком.
    static let mediaHTTPHeaders: [String: String] = [
        "Referer": "https://video.sibnet.ru/",
        "User-Agent": desktopChromeUserAgent
    ]

    /// Referer запросов к странице `shell.php` — **корень** сайта `sibnet.ru`.
    ///
    /// Reference-клиент шлёт именно его, а не `https://video.sibnet.ru/`:
    /// страница плеера живёт на корне домена, и от этого Referer зависит ответ.
    static let pageReferer = "https://sibnet.ru/"

    /// `Accept` страницы `shell.php` — как в reference-клиенте (полный браузерный набор).
    static let pageAccept =
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    /// `Accept-Language` страницы `shell.php` — как в reference-клиенте.
    static let pageAcceptLanguage = "ru-RU,ru;q=0.9,en-US;q=0.8"

    /// Мобильный Safari UA — первая попытка запроса `shell.php`.
    static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    /// Android WebView UA — запасная попытка, если основная получила `403`.
    ///
    /// В оригинале UA всегда приходит с сервера (`config/toggles.sibnetUserAgent`);
    /// этот UA — фолбэк iOS-порта, пока toggles не подключены.
    static let androidWebViewUserAgent =
        "Mozilla/5.0 (Linux; Android 13; SM-S908B) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    /// Регулярки пути видео из HTML — в порядке приоритета, как в reference-клиенте.
    ///
    /// Более точные (`player.src`, `*.mp4`, `shell.php`) идут раньше общего
    /// `src: "/..."`, иначе общая регулярка перехватила бы не тот путь.
    static let srcPatterns: [String] = [
        #"player\.src\(\[\s*\{\s*src:\s*"(\/[^"]+)"#,
        #"src:\s*"(\/v\/[^"]+\.mp4[^"]*)"#,
        #"src:\s*"(\/shell\.php\?[^"]+)"#,
        #"src:\s*"(\/[^"]+)"#,
        #"src:\s*'(\/[^']+)'"#,
        #"file\s*:\s*"(\/shell\.php[^"]+)"#
    ]

    private static let srcExpressions: [NSRegularExpression] =
        srcPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    /// Маркеры страницы «видео недоступно» (нижний регистр, сравнение без учёта регистра).
    static let unavailableMarkers: [String] = [
        "видео удалено",
        "видео не найдено",
        "видео не существует",
        "удалено пользователем",
        "video deleted",
        "video not found",
        "access denied"
    ]

    /// Признаки `Content-Type` готового медиафайла (нижний регистр, подстрока).
    static let videoContentTypeMarkers: [String] = [
        "video/",
        "octet-stream",
        "mp4",
        "mpegurl"
    ]

    /// Таймаут запроса `shell.php` — 14 с, как в оригинальном парсере.
    private static let shellTimeout: TimeInterval = 14

    /// Таймаут запроса резолва редиректа: цепочка из 1–2 коротких ответов.
    private static let redirectTimeout: TimeInterval = 15

    /// Сколько редиректов максимум проходим (защита от петли).
    private static let maxRedirectHops = 5

    /// Сессия для HTML: редиректы `shell.php` (если есть) обрабатывает сама `URLSession`.
    private static let htmlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = shellTimeout
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// Сессия для резолва редиректа: не следует 3xx автоматически.
    ///
    /// Оригинал тоже запрещает переход (`followRedirects = false`) и читает `Location`.
    /// Нам это нужно и по другой причине: если сервер сразу отдаёт файл, автопереход
    /// скачал бы весь MP4 в память, а нам нужен только итоговый URL.
    private static let redirectSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = redirectTimeout
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration,
                          delegate: RedirectBlocker(),
                          delegateQueue: nil)
    }()

    // MARK: - Публичный вход

    /// Достаёт прямую ссылку на MP4 из `shell.php` и отдаёт её нативному плееру.
    ///
    /// - Parameters:
    ///   - url: подписанный URL серии из `episode/target` (`iframe == false`).
    ///   - title: заголовок для экрана плеера.
    /// - Throws: `PlaybackError.playbackUnavailable`, если Sibnet говорит, что видео
    ///   нет; `PlaybackError.resolutionFailed`, если ссылку получить не удалось.
    static func resolve(url: URL, title: String) async throws -> PlaybackTarget {
        try await resolve(url: url, title: title, userAgent: nil)
    }

    /// То же, но с UA из `config/toggles` (`sibnetUserAgent`), если он уже загружен.
    ///
    /// По документации оригинал всегда ходит с серверным UA: он мобильный и ротируется
    /// на каждый запрос (`sibnetRandUserAgent: true`). Этот параметр — точка подключения,
    /// когда в iOS появится `ConfigRepository`; пока он `nil`, последовательность попыток
    /// такая: мобильный Safari → (при `403`) Android WebView UA с `Referer` на `sibnet.ru/`.
    static func resolve(url: URL, title: String, userAgent: String?) async throws -> PlaybackTarget {
        guard let host = url.host?.lowercased(),
              host == "sibnet.ru" || host.hasSuffix(".sibnet.ru") else {
            throw PlaybackError.resolutionFailed("ссылка ведёт не на Sibnet: \(url.host ?? "—")")
        }

        let (html, usedUserAgent) = try await loadShellHTML(url: url, togglesUserAgent: userAgent)

        guard let rawPath = srcPath(in: html) else {
            throw PlaybackError.resolutionFailed("в ответе Sibnet нет ссылки src на видео")
        }
        guard let candidate = absoluteURL(rawPath, relativeTo: url) else {
            throw PlaybackError.resolutionFailed("некорректная ссылка на видео: \(rawPath)")
        }

        let mediaURL = try await followingRedirects(from: candidate,
                                                    shellURL: url,
                                                    userAgent: usedUserAgent)

        return PlaybackTarget(
            kind: .hls(mediaURL),
            title: title,
            providerName: providerName,
            referer: Self.referer,
            variants: nil,
            httpHeaders: mediaHTTPHeaders
        )
    }

    // MARK: - Запрос shell.php

    /// Скачивает HTML `shell.php`, при `403` повторяет запрос с запасным UA.
    ///
    /// Возвращает HTML и UA, которым удалось его получить: тем же UA резолвим редирект.
    /// Порядок: UA из toggles (если есть) или мобильный Safari → Android WebView UA.
    private static func loadShellHTML(url: URL,
                                      togglesUserAgent: String?) async throws -> (String, String) {
        let primaryUserAgent = normalizedUserAgent(togglesUserAgent) ?? mobileSafariUserAgent
        var userAgents = [primaryUserAgent]
        if androidWebViewUserAgent != primaryUserAgent {
            userAgents.append(androidWebViewUserAgent)
        }

        var lastStatus = 0
        for userAgent in userAgents {
            let result = try await send(request(for: url, userAgent: userAgent),
                                        session: htmlSession)
            lastStatus = result.status
            if result.status == 200 {
                let html = String(decoding: result.data, as: UTF8.self)
                // Страница «видео удалено» — валидный 200 HTML. Это не таймаут
                // и не сетевой сбой: смотреть нечего, отдельная ошибка.
                guard !isUnavailableHTML(html) else {
                    throw PlaybackError.playbackUnavailable
                }
                return (html, userAgent)
            }
            // Чужой код (404/500) повтором с другим UA не лечится — сразу наверх.
            // Повторяем только на 403: так ведёт себя reference-клиент.
            guard result.status == 403 else {
                throw PlaybackError.resolutionFailed("HTTP \(result.status)")
            }
        }

        throw PlaybackError.resolutionFailed("HTTP \(lastStatus)")
    }

    /// Запрос страницы `shell.php` с полным набором браузерных заголовков.
    private static func request(for url: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: shellTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(pageReferer, forHTTPHeaderField: "Referer")
        request.setValue(pageAccept, forHTTPHeaderField: "Accept")
        request.setValue(pageAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        return request
    }

    // MARK: - Редирект на MP4

    /// Проходит 3xx-цепочку «путь видео → готовый MP4», не скачивая сам файл.
    ///
    /// Каждый шаг — GET с `Referer` подписанного `shell.php`, тем же UA,
    /// `Accept: */*` и `Range: bytes=0-0`: ответы-редиректы тела не отдают,
    /// а если сервер уже отдаёт файл, диапазон ограничивает чтение одним байтом.
    /// `Location` разворачиваем сами (оригинал: `followRedirects = false`),
    /// потому что итоговый URL нужен как `PlaybackTarget`.
    private static func followingRedirects(from candidate: URL,
                                           shellURL: URL,
                                           userAgent: String) async throws -> URL {
        var current = candidate
        let referer = shellURL.absoluteString

        for _ in 0..<maxRedirectHops {
            var request = URLRequest(url: current,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: redirectTimeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

            let result = try await send(request, session: redirectSession)

            if (300..<400).contains(result.status) {
                guard let location = result.response.value(forHTTPHeaderField: "Location"),
                      let next = redirectURL(location: location, relativeTo: current) else {
                    throw PlaybackError.resolutionFailed("Sibnet вернул непригодный редирект")
                }
                current = removingDefaultPort(next)
                continue
            }

            // 206 — честный ответ на Range, 200 — сервер диапазон проигнорировал.
            guard result.status == 200 || result.status == 206 else {
                throw PlaybackError.resolutionFailed("HTTP \(result.status)")
            }

            // Готовая ссылка — только ответ с медиа-типом. Всё остальное — страница
            // ошибки/заглушка: не отдаём в AVPlayer заведомо битый URL.
            let contentType = result.response.value(forHTTPHeaderField: "Content-Type")
            guard isVideoContentType(contentType) else {
                let body = String(decoding: result.data.prefix(64 * 1024), as: UTF8.self)
                if isUnavailableHTML(body) {
                    throw PlaybackError.playbackUnavailable
                }
                let type = (contentType ?? "").lowercased()
                let looksLikeHTML = type.contains("text/html")
                    || body.lowercased().contains("<html")
                throw PlaybackError.resolutionFailed(
                    looksLikeHTML
                        ? "Sibnet вернул страницу вместо видео"
                        : "Sibnet вернул ответ без видео: \(contentType ?? "без Content-Type")"
                )
            }
            return removingDefaultPort(current)
        }

        throw PlaybackError.resolutionFailed("слишком много редиректов Sibnet")
    }

    // MARK: - Разбор HTML

    /// Путь видео из HTML `shell.php` — по регуляркам в порядке приоритета.
    ///
    /// Возвращает `nil`, если ни одна регулярка не сработала (пустая страница,
    /// изменившийся формат плеера).
    static func srcPath(in html: String) -> String? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for expression in srcExpressions {
            guard let match = expression.firstMatch(in: html, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            let value = String(html[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Страница «видео недоступно» — удалено/не найдено/закрыто (без учёта регистра).
    ///
    /// Такая страница приходит с `200`, поэтому её нужно отличить от сетевого
    /// сбоя: наверх уходит `playbackUnavailable`, а не `resolutionFailed`.
    static func isUnavailableHTML(_ html: String) -> Bool {
        let lowercased = html.lowercased()
        return unavailableMarkers.contains { lowercased.contains($0) }
    }

    /// `Content-Type` похож на готовый медиафайл (`video/*`, `octet-stream`, `mp4`, HLS).
    static func isVideoContentType(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased(), !type.isEmpty else { return false }
        return videoContentTypeMarkers.contains { type.contains($0) }
    }

    /// Достраивает ссылку: абсолютную берёт как есть, относительную — от `shell.php`.
    ///
    /// Reference-клиент приклеивает к найденному пути `https://video.sibnet.ru`;
    /// здесь путь резолвится от базового URL (он всегда `video.sibnet.ru`), а
    /// абсолютный URL и `//host/...` поддержаны на случай смены формата.
    static func absoluteURL(_ raw: String, relativeTo base: URL) -> URL? {
        let value = normalize(raw)
        guard !value.isEmpty else { return nil }

        // Абсолютный URL.
        if let url = URL(string: value), url.scheme != nil, url.host != nil {
            return url
        }
        // Protocol-relative `//host/path` — подставляем схему базового URL.
        if value.hasPrefix("//"), let scheme = base.scheme,
           let url = URL(string: "\(scheme):\(value)") {
            return url
        }
        // Относительный путь (`/v/xxx.mp4` или `v/xxx.mp4`) — от `shell.php`.
        return URL(string: value, relativeTo: base)?.absoluteURL
    }

    /// Следующий адрес из `Location`: абсолютный, относительный или protocol-relative.
    ///
    /// `nil` — если Location пустой, не http(s) или ведёт на заведомо HTML-страницу
    /// (такой прыжок ничего не даст: вместо видео придёт страница).
    static func redirectURL(location: String, relativeTo base: URL) -> URL? {
        guard let url = absoluteURL(location, relativeTo: base),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        let extensionName = url.pathExtension.lowercased()
        guard extensionName != "html", extensionName != "htm" else { return nil }
        return url
    }

    /// Убирает явный порт по умолчанию: оригинал удаляет `:443` из результата резолва.
    static func removingDefaultPort(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              url.absoluteString.contains("://\(host):443") else {
            return url
        }
        let cleaned = url.absoluteString.replacingOccurrences(of: "://\(host):443",
                                                              with: "://\(host)")
        return URL(string: cleaned) ?? url
    }

    /// Разворачивает HTML-сущности и JSON-экранирование в значении пути.
    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    /// Пустой или пробельный UA из toggles не используем.
    private static func normalizedUserAgent(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - HTTP

    private struct HTTPResult {
        let data: Data
        let response: HTTPURLResponse
        var status: Int { response.statusCode }
    }

    /// Выполняет запрос и переводит сетевые/HTTP-сбои в `PlaybackError`.
    private static func send(_ request: URLRequest, session: URLSession) async throws -> HTTPResult {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PlaybackError.resolutionFailed("Sibnet ответил не по HTTP")
            }
            return HTTPResult(data: data, response: http)
        } catch let error as PlaybackError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PlaybackError.resolutionFailed(error.localizedDescription)
        }
    }
}

// MARK: - Подавление автоперехода

/// Отклоняет HTTP-редиректы, чтобы `URLSession` отдала ответ 3xx с `Location`.
///
/// Так мы получаем итоговый адрес и не скачиваем видеофайл: переход по `Location`
/// делает сам резолвер, читая заголовки ответа.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Подключение

// Вызывается из PlayerView (или EpisodePlaybackService) перед показом, когда сервер
// отдал `iframe == false` и источник — Sibnet (проверять по хосту URL, а не по `name`):
//
//     if episode.iframe != true, VideoProvider.detect(sourceName: source.name, url: url) == .sibnet {
//         let target = try await SibnetResolver.resolve(url: url, title: episode.displayName)
//         playback = target              // .hls(mp4) → NativePlayerView / AVPlayer
//     }
//
// Ошибки — `PlaybackError` с готовым русским текстом: их можно показывать
// в `PlayerPhase.failed` как есть. Для release 1034 `name` тоже «Sibnet»,
// но URL ведёт на `vk.com` — это другой парсер, сюда такой URL передавать нельзя
// (резолвер отклонит его с явной ошибкой).
//
// Позиции серий: у Sibnet они 0-базовые (`position: 0` = «1 серия», проверено
// живым API 24.11.2026). `episode/target/.../1` — это уже «2 серия», поэтому
// никаких перестановок/повторов позиций в этом резолвере нет: он получает URL
// серии и не знает номера, а вызывающий код передаёт позицию из `episodes[]`.
