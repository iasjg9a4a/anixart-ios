import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif

/// Прямая ссылка для нативного плеера из HTML-вставки Sibnet.
///
/// Android-приложение не показывает `shell.php` в WebView, а вытаскивает из его HTML
/// адрес MP4 (`SibnetParser`):
///
/// 1. GET `shell.php` с мобильным User-Agent из `config/toggles` (`sibnetUserAgent`),
///    без Referer, таймаут 14 с.
/// 2. HTML-регулярка `src: "(.*?)"` (`analysis/strings.txt:205091`) вытаскивает путь
///    видео; к нему приклеивается `https://video.sibnet.ru` (`analysis/strings.txt:198334`).
/// 3. GET этого URL с `Referer: <shell.php>` и `followRedirects = false`, читается
///    `Location`; ссылка нормализуется — из неё убирается `:443`.
/// 4. Готовая ссылка (качество `Default`) уходит в ExoPlayer.
///
/// Здесь шаги 1–3 повторены на `URLSession`, а результат отдаётся как
/// `PlaybackTarget(kind: .hls(...))`: по контракту `PlaybackKind.hls` — это любой
/// прямой поток, включая MP4 (см. комментарий в `PlaybackTarget.swift`).
///
/// ## Что подтверждено
/// * Хост `video.sibnet.ru` → `SibnetParser`, регулярка `src: "(.*?)"`, приклеивание
///   `https://video.sibnet.ru`, `Referer: shell.php` на резолве редиректа и удаление
///   `:443` — из dex (`analysis/strings.txt:198334`, `:206011`, `:205091`) и
///   `docs/PLAYERS.md` §3.
/// * С нашего IP `shell.php` (и корень `video.sibnet.ru`) отвечает
///   `403 Forbidden` / `Request forbidden by administrative rules` для всех UA —
///   региональная блокировка; python-проба 24.11.2026. Это блокировка именно
///   видеохоста: `help.sibnet.ru` с того же IP отвечает `200`.
/// * UA лежит в `config/toggles` (`getSibnetUserAgent` — `analysis/strings.txt:197628`,
///   `sibnetUserAgent` — `:204964`), при `sibnetRandUserAgent: true` (`:197627`) он
///   мобильный и меняется на каждый запрос (`docs/PLAYERS.md` §1.2).
///
/// ## Что НЕ подтверждено — проверять на устройстве (см. `docs/PLAYERS.md` §12.3)
/// * Живой HTML `shell.php`: реальный вид значения `src` (относительный путь или
///   абсолютный URL), наличие и параметры редиректа, на какой хост он ведёт.
/// * Что проходит мобильный Safari UA: из dex известен только сам факт, что UA
///   обязателен. Запасной Android WebView UA + `Referer` — эвристика iOS-порта.
/// * Что AVPlayer играет итоговый MP4 с `Referer: https://video.sibnet.ru/`.
/// * `config/toggles.sibnetUserAgent` в iOS ещё не перенесён, поэтому UA по умолчанию —
///   захардкоженный мобильный Safari; когда появится `ConfigRepository`, серверный UA
///   можно передать в перегрузку `resolve(url:title:userAgent:)`.
enum SibnetResolver {

    // MARK: - Константы

    /// Имя источника для UI и логов (`PlaybackTarget.providerName`).
    static let providerName = "Sibnet"

    /// Referer, который кладётся в `PlaybackTarget`: корень сайта, как в контракте.
    static let referer: URL? = URL(string: "https://video.sibnet.ru/")

    /// Referer для повторного запроса `shell.php` с запасным UA — корень сайта.
    ///
    /// Для резолва редиректа Referer другой: там нужен сам подписанный `shell.php`
    /// (`docs/PLAYERS.md` §3), а не этот корень.
    private static let siteRootReferer = "https://video.sibnet.ru/"

    /// Мобильный Safari UA — первая попытка запроса `shell.php`.
    static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    /// Android WebView UA — запасная попытка, если мобильный Safari получил `403`.
    ///
    /// В оригинале UA всегда приходит с сервера (`config/toggles.sibnetUserAgent`);
    /// этот UA — фолбэк iOS-порта, пока toggles не подключены.
    static let androidWebViewUserAgent =
        "Mozilla/5.0 (Linux; Android 13; SM-S908B) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    /// Регулярка из dex — `src: "(.*?)"`, но вместо `.*?` класс `[^"]+`:
    /// он и останавливается на кавычке, и не пропускает пустое значение.
    private static let srcPattern = #"src\s*:\s*"([^"]+)"#

    private static let srcExpression = try? NSRegularExpression(pattern: srcPattern)

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
    /// - Throws: `PlaybackError.resolutionFailed`, если ссылку получить не удалось.
    static func resolve(url: URL, title: String) async throws -> PlaybackTarget {
        try await resolve(url: url, title: title, userAgent: nil)
    }

    /// То же, но с UA из `config/toggles` (`sibnetUserAgent`), если он уже загружен.
    ///
    /// По документации оригинал всегда ходит с серверным UA: он мобильный и ротируется
    /// на каждый запрос (`sibnetRandUserAgent: true`). Этот параметр — точка подключения,
    /// когда в iOS появится `ConfigRepository`; пока он `nil`, последовательность попыток
    /// такая: мобильный Safari → (при `403`) Android WebView UA с `Referer`.
    static func resolve(url: URL, title: String, userAgent: String?) async throws -> PlaybackTarget {
        guard let host = url.host?.lowercased(), host.hasSuffix("sibnet.ru") else {
            throw PlaybackError.resolutionFailed("ссылка ведёт не на Sibnet: \(url.host ?? "—")")
        }

        let (html, usedUserAgent) = try await loadShellHTML(url: url, togglesUserAgent: userAgent)

        guard let rawPath = videoPath(in: html) else {
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
            referer: Self.referer
        )
    }

    // MARK: - Запрос shell.php

    /// Скачивает HTML `shell.php`, при `403` повторяет запрос с запасным UA.
    ///
    /// Возвращает HTML и UA, которым удалось его получить: тем же UA резолвим редирект.
    private static func loadShellHTML(url: URL, togglesUserAgent: String?) async throws -> (String, String) {
        // 1) мобильный Safari без Referer, 2) при 403 — toggles-UA или Android WebView,
        // c Referer на корень сайта.
        let fallbackUserAgent = normalizedUserAgent(togglesUserAgent) ?? androidWebViewUserAgent
        let attempts: [(userAgent: String, referer: String?)] = [
            (mobileSafariUserAgent, nil),
            (fallbackUserAgent, siteRootReferer)
        ]

        var lastStatus = 0
        for attempt in attempts {
            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: shellTimeout)
            request.setValue(attempt.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            if let referer = attempt.referer {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }

            let result = try await send(request, session: htmlSession)
            lastStatus = result.status
            if result.status == 200 {
                return (String(decoding: result.data, as: UTF8.self), attempt.userAgent)
            }
            // Чужой код (404/500) повтором с другим UA не лечится — сразу наверх.
            guard result.status == 403 else {
                throw PlaybackError.resolutionFailed("HTTP \(result.status)")
            }
        }

        throw PlaybackError.resolutionFailed("HTTP \(lastStatus)")
    }

    // MARK: - Редирект на MP4

    /// Проходит 302-цепочку «путь видео → готовый MP4», не скачивая сам файл.
    ///
    /// Каждый шаг — GET с `Referer` подписанного `shell.php` и `Range: bytes=0-0`:
    /// ответы-редиректы тела не отдают, а если сервер уже отдаёт файл, диапазон
    /// ограничивает чтение одним байтом. `Location` разворачиваем сами (оригинал:
    /// `followRedirects = false`), потому что итоговый URL нужен как `PlaybackTarget`.
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
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

            let result = try await send(request, session: redirectSession)

            if (300..<400).contains(result.status) {
                guard let location = result.response.value(forHTTPHeaderField: "Location"),
                      let next = absoluteURL(location, relativeTo: current) else {
                    throw PlaybackError.resolutionFailed("Sibnet вернул редирект без Location")
                }
                current = removingDefaultPort(next)
                continue
            }

            // 206 — честный ответ на Range, 200 — сервер диапазон проигнорировал.
            guard result.status == 200 || result.status == 206 else {
                throw PlaybackError.resolutionFailed("HTTP \(result.status)")
            }
            // Если вместо видео пришла HTML-страница (истёкшая подпись, ошибка Sibnet),
            // лучше сказать об этом сразу, чем отдать в AVPlayer заведомо битый URL.
            let contentType = result.response.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard !contentType.lowercased().contains("text/html") else {
                throw PlaybackError.resolutionFailed("Sibnet вернул страницу вместо видео")
            }
            return removingDefaultPort(current)
        }

        throw PlaybackError.resolutionFailed("слишком много редиректов Sibnet")
    }

    // MARK: - Разбор HTML

    /// Значение `src: "..."` из HTML `shell.php` — путь или URL видео.
    private static func videoPath(in html: String) -> String? {
        guard let expression = srcExpression else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let value = String(html[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Достраивает ссылку: абсолютную берёт как есть, относительную — от `shell.php`.
    ///
    /// В оригинале к найденному пути просто приклеивается `https://video.sibnet.ru`;
    /// вариант с абсолютным URL поддержан на случай, если Sibnet начнёт отдавать его.
    private static func absoluteURL(_ raw: String, relativeTo base: URL) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value), url.scheme != nil, url.host != nil {
            return url
        }
        // Относительный путь (`/v/xxx.mp4`) или protocol-relative (`//video.sibnet.ru/...`).
        return URL(string: value, relativeTo: base)?.absoluteURL
    }

    /// Убирает явный порт по умолчанию: оригинал удаляет `:443` из результата резолва.
    private static func removingDefaultPort(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              url.absoluteString.contains("://\(host):443") else {
            return url
        }
        let cleaned = url.absoluteString.replacingOccurrences(of: "://\(host):443",
                                                              with: "://\(host)")
        return URL(string: cleaned) ?? url
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

// Вызывается из PlayerView (или ReleaseViewModel) перед показом, когда сервер отдал
// `iframe == false` и источник — Sibnet (проверять по хосту URL, а не по `name`):
//
//     if episode.iframe != true, VideoProvider.detect(sourceName: source.name, url: url) == .sibnet {
//         let target = try await SibnetResolver.resolve(url: url, title: episode.displayName)
//         playback = target              // .hls(mp4) → NativePlayerView / AVPlayer
//     }
//
// Ошибки — `PlaybackError.resolutionFailed` с готовым русским текстом: их можно
// показывать в `PlayerPhase.failed` как есть. Для release 1034 `name` тоже «Sibnet»,
// но URL ведёт на `vk.com` — это другой парсер, сюда такой URL передавать нельзя
// (резолвер отклонит его с явной ошибкой).
