import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле — как в APIClient.swift
#endif

/// Нативный разбор RuTube: HTML-страница видео → прямой HLS-поток для `AVPlayer`.
///
/// Повторяет Android-парсер `RuTubeParser` (`docs/PLAYERS.md` §5; dex:
/// `analysis/strings.txt:203280-203284`, `:198327-198328`, `:188310-188317`):
///
/// 1. из ссылки достаётся 32-hex идентификатор — четыре шаблона: `video/`, `play/embed/`,
///    `shorts/`, `video/private/` (у private-ссылки ещё и ключ доступа `?p=`);
/// 2. GET `api/play/options/{id}/?no_404=true&referer&pver=v2` с `Referer: https://rutube.ru/`
///    и десктопным User-Agent, таймаут 10 с;
/// 3. из `video_balancer.m3u8` (фолбэк — `video_balancer.default`) читается master-плейлист
///    и выбирается вариант с лучшим `RESOLUTION`/`BANDWIDTH`;
/// 4. регион-лок (`detail.type == "blocking_rule"`) и прямой эфир (непустой `live_streams.hls`)
///    превращаются в понятную `PlaybackError.resolutionFailed`.
///
/// Шаблона `rutube.ru/tasks/{id}` в dex нет: там именно четыре перечисленных выше, поэтому
/// `videoId(from:)` повторяет их.
///
/// Импорт выше условный: на iOS `FoundationNetworking` не существует, на Linux — только там
/// живёт `URLSession`. Так же сделано в `Core/APIClient.swift`.
enum RutubeResolver {

    // MARK: - Константы

    /// Referer, который ожидает API (`analysis/strings.txt:198327`).
    private static let referer = URL(string: "https://rutube.ru/")

    /// Обычный десктопный User-Agent: у Android media-запросы ходят с ним
    /// (`analysis/strings.txt:186561`, `docs/PLAYERS.md` §9).
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.45 Safari/537.36"

    /// Таймаут запросов из dex — 10 секунд.
    private static let timeout: TimeInterval = 10

    /// Четыре шаблона ссылок из dex (`analysis/strings.txt:203281-203284`).
    private static let videoIDPatterns = [
        "rutube\\.ru/video/private/([a-f0-9]{32})",
        "rutube\\.ru/play/embed/([a-f0-9]{32})",
        "rutube\\.ru/shorts/([a-f0-9]{32})",
        "rutube\\.ru/video/([a-f0-9]{32})"
    ]

    // MARK: - Идентификатор

    /// Достаёт 32-hex id из ссылок `rutube.ru/video/{id}/`, `.../play/embed/{id}`,
    /// `.../shorts/{id}` и `.../video/private/{id}?p={key}`.
    ///
    /// - Returns: `nil`, если ссылка не RuTube или id в ней нет.
    static func videoId(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), isRutubeHost(host) else { return nil }
        let string = url.absoluteString.lowercased()
        for pattern in videoIDPatterns {
            guard let match = string.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let component = string[match].split(separator: "/").last.map(String.init) ?? ""
            return component.isEmpty ? nil : component
        }
        return nil
    }

    /// Ключ доступа `?p=` у private-видео; обычные ссылки его не несут.
    private static func privateKey(from url: URL) -> String? {
        guard url.path.contains("/video/private/") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "p" })?
            .value
    }

    private static func isRutubeHost(_ host: String) -> Bool {
        host == "rutube.ru" || host.hasSuffix(".rutube.ru")
    }

    // MARK: - Разбор

    /// Превращает ссылку RuTube в `.hls` с лучшим качеством.
    ///
    /// - Parameters:
    ///   - url: ссылка из `episode/target` (`video`, `play/embed`, `shorts`, `video/private`).
    ///   - title: заголовок для экрана плеера.
    /// - Throws: `PlaybackError.resolutionFailed` — нет id, регион-лок, прямой эфир,
    ///   удалённое видео, сетевая ошибка или неразбираемый ответ.
    static func resolve(url: URL, title: String) async throws -> PlaybackTarget {
        guard let videoID = videoId(from: url) else {
            throw PlaybackError.resolutionFailed("не удалось найти id видео RuTube в ссылке")
        }

        let optionsURL = try makeOptionsURL(videoID: videoID, privateKey: privateKey(from: url))
        let optionsData = try await fetch(optionsURL)
        let options: RutubePlayOptions
        do {
            options = try makeDecoder().decode(RutubePlayOptions.self, from: optionsData)
        } catch {
            throw PlaybackError.resolutionFailed("не удалось разобрать ответ RuTube")
        }

        // Регион-лок RuTube (`analysis/strings.txt:192914`).
        if options.detail?.type == "blocking_rule" {
            throw PlaybackError.resolutionFailed("Видео заблокировано в вашем регионе")
        }

        // Android-парсер прямой эфир не поддерживает — сигнал в `LiveStreams.hls`.
        if let live = options.liveStreams?.hls, !live.isEmpty {
            throw PlaybackError.resolutionFailed("Прямой эфир RuTube не поддерживается")
        }

        // `no_404=true` на удалённое видео отдаёт нестандартный HTTP 244 и `detail.type ==
        // "action_reason"` вместо 404 (проверено живьём) — `video_balancer` в ответе нет.
        guard let master = options.videoBalancer?.m3u8 ?? options.videoBalancer?.default,
              !master.isEmpty,
              let masterURL = URL(string: master) else {
            throw PlaybackError.resolutionFailed("Видео недоступно или не существует")
        }

        // Если master-плейлист прочитать не удалось, отдаём его как есть: AVPlayer разберёт
        // варианты сам (так же поступает Android, когда не может распарсить m3u8).
        let streamURL = await bestVariant(in: masterURL) ?? masterURL
        return PlaybackTarget(
            kind: .hls(streamURL),
            title: title,
            providerName: "RuTube",
            referer: referer
        )
    }

    /// URL `play/options` из dex (`analysis/strings.txt:198328`):
    /// `/api/play/options/{id}/?no_404=true&referer&pver=v2`; для private — ещё `&p={key}`.
    private static func makeOptionsURL(videoID: String, privateKey: String?) throws -> URL {
        guard var components = URLComponents(string: "https://rutube.ru/api/play/options/\(videoID)/") else {
            throw PlaybackError.resolutionFailed("некорректный адрес RuTube")
        }
        var items = [
            URLQueryItem(name: "no_404", value: "true"),
            URLQueryItem(name: "referer", value: nil),   // в dex параметр без значения
            URLQueryItem(name: "pver", value: "v2")
        ]
        if let privateKey, !privateKey.isEmpty {
            items.append(URLQueryItem(name: "p", value: privateKey))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw PlaybackError.resolutionFailed("не удалось собрать адрес запроса RuTube")
        }
        return url
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: - Сеть

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://rutube.ru/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PlaybackError.resolutionFailed("RuTube вернул некорректный ответ")
            }
            guard (200...299).contains(http.statusCode) else {
                throw PlaybackError.resolutionFailed("RuTube ответил HTTP \(http.statusCode)")
            }
            guard !data.isEmpty else {
                throw PlaybackError.resolutionFailed("RuTube вернул пустой ответ")
            }
            return data
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.resolutionFailed("нет связи с RuTube: \(error.localizedDescription)")
        }
    }

    // MARK: - Master-плейлист

    /// Один вариант качества из master-m3u8.
    private struct RutubeStreamVariant {
        let url: URL
        let width: Int
        let height: Int
        let bandwidth: Int

        /// Android-парсер сравнивает `max(width, height)`, затем `BANDWIDTH`.
        var rank: (Int, Int) { (max(width, height), bandwidth) }
    }

    /// Читает master-плейлист и отдаёт вариант с лучшим качеством.
    ///
    /// `nil` — плейлист не прочитался (сеть, нестандартный ответ); вызывающий тогда
    /// возвращает master-URL, и варианты выбирает сам `AVPlayer`.
    private static func bestVariant(in masterURL: URL) async -> URL? {
        guard let data = try? await fetch(masterURL),
              let playlist = String(data: data, encoding: .utf8) else { return nil }
        return parseVariants(from: playlist, relativeTo: masterURL).first?.url
    }

    /// Разбор master-плейлиста, как в `RuTubeParser.parseM3u8Variants`: пара
    /// `#EXT-X-STREAM-INF:` (с `RESOLUTION`/`BANDWIDTH`) и URI следующей строкой,
    /// сортировка по убыванию качества и `BANDWIDTH`.
    private static func parseVariants(from playlist: String,
                                      relativeTo baseURL: URL) -> [RutubeStreamVariant] {
        var variants: [RutubeStreamVariant] = []
        var pending: (width: Int, height: Int, bandwidth: Int)?
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = streamAttributes(in: line)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let attributes = pending,
                  let url = URL(string: line, relativeTo: baseURL) else {
                pending = nil
                continue
            }
            pending = nil
            variants.append(
                RutubeStreamVariant(
                    url: url.absoluteURL,
                    width: attributes.width,
                    height: attributes.height,
                    bandwidth: attributes.bandwidth
                )
            )
        }
        return variants.sorted { $0.rank > $1.rank }
    }

    /// `RESOLUTION=WxH` и `BANDWIDTH` строки `#EXT-X-STREAM-INF:`; оба обязательны,
    /// иначе вариант пропускается.
    private static func streamAttributes(in line: String) -> (width: Int, height: Int, bandwidth: Int)? {
        let resolution = attribute("RESOLUTION", in: line)?.split(separator: "x") ?? []
        guard resolution.count == 2,
              let width = Int(String(resolution[0])),
              let height = Int(String(resolution[1])),
              let bandwidth = attribute("BANDWIDTH", in: line).flatMap({ Int($0) }) else {
            return nil
        }
        return (width, height, bandwidth)
    }

    /// Значение атрибута `NAME=...` в строке `#EXT-X-STREAM-INF:`.
    ///
    /// Имя ищется только как отдельный атрибут (в начале строки или после `,`/`:`),
    /// чтобы `BANDWIDTH=` не совпал с хвостом `AVERAGE-BANDWIDTH=`.
    private static func attribute(_ name: String, in line: String) -> String? {
        let marker = name + "="
        var searchStart = line.startIndex
        while let range = line.range(of: marker, range: searchStart..<line.endIndex) {
            if range.lowerBound == line.startIndex {
                return attributeValue(after: range.upperBound, in: line)
            }
            let previous = line[line.index(before: range.lowerBound)]
            if previous == "," || previous == ":" {
                return attributeValue(after: range.upperBound, in: line)
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func attributeValue(after start: String.Index, in line: String) -> String? {
        let rest = line[start...]
        let end = rest.firstIndex(where: { $0 == "," }) ?? rest.endIndex
        let value = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: - JSON

    /// Ответ `api/play/options/{id}`; все поля необязательные — RuTube умеет отдавать
    /// частичный ответ (например, только `detail` для удалённого видео).
    private struct RutubePlayOptions: Decodable {
        let videoBalancer: RutubeVideoBalancer?
        let liveStreams: RutubeLiveStreams?
        let detail: RutubeDetail?
    }

    /// `video_balancer`: `m3u8` — master-плейлист, `default` — фолбэк с той же ссылкой
    /// (живой ответ содержит оба ключа).
    private struct RutubeVideoBalancer: Decodable {
        let m3u8: String?
        let `default`: String?
    }

    /// `live_streams`: непустой `hls` означает прямой эфир.
    private struct RutubeLiveStreams: Decodable {
        let hls: String?
    }

    /// `detail.type`: `"blocking_rule"` — регион-лок, у удалённого видео — `"action_reason"`.
    private struct RutubeDetail: Decodable {
        let type: String?
    }
}
