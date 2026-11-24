import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif

/// Превращает ссылку источника AnixPlayer (StudioMir) в прямой HLS-поток.
///
/// `episode/target/...` для AnixPlayer отдаёт HTML-страницу
/// `https://api.studiomir.club/tsmplayer/embed?ani=53&plf=anixart&ep=1` (`iframe: true`).
/// Открывать её в WKWebView нельзя: iframe-прокси Anixart помечает `studiomir.club`
/// как `unsupported`, поэтому ссылка разбирается по API StudioMir:
///
/// 1. из ссылки достаются `ani` (id аниме) и `ep` (номер серии);
/// 2. `GET https://api.studiomir.club/api?ani={ani}&apikey={key}` — apikey захардкожен
///    в оригинальном приложении (`analysis/strings.txt:162054`);
/// 3. ответ — JSON-массив; у первого элемента берётся `players.tsm[]`, серия
///    выбирается по `episode == ep` с приоритетом `type == "TV"`, затем `"TR"`;
/// 4. лучшее непустое качество `hls` (`2160p` → `1080p` → `720p`), иначе `url`.
///
/// Форма ответа подтверждена живыми запросами 24.11.2026 (ani=1 и ani=53): массив
/// из одного элемента, у `tsm[]` поля `episode`, `type`, `url` и
/// `hls: {"2160p", "1080p", "720p"}`; выбранная `m3u8` отвечает
/// `200 application/vnd.apple.mpegurl` (Referer не нужен). Без apikey API отвечает
/// `403`, для несуществующего `ani` — `404`.
enum AnixPlayerResolver {

    // MARK: - Константы

    /// Ключ из dex оригинального приложения. Проверено: с ним `200`, без него и
    /// с неверным — `403`.
    static let apiKey = "80b2d3e9c4ff27eb2e924c4d38f7daec"

    /// Эндпоинт StudioMir. Принимает query-параметры `ani` и `apikey`.
    static let apiBase = "https://api.studiomir.club/api"

    /// Имя источника для `PlaybackTarget.providerName`.
    static let providerName = "AnixPlayer"

    /// Referer, который ожидает плеер StudioMir (для API и HLS не требуется).
    static let referer: URL? = URL(string: "https://studiomir.club/")

    /// UA нативного парсера оригинала. API отвечает и без него, но сервер может
    /// начать фильтровать клиентов.
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"

    /// Таймаут запроса к API — как у `StudioMirParser` в оригинале.
    private static let timeout: TimeInterval = 14

    /// Имена query-параметров, в которых Anixart/StudioMir кладут id аниме.
    private static let aniQueryNames = ["ani", "anime_id", "animeid", "anime-id"]

    // MARK: - Разбор ссылки

    /// Достаёт `ani` из ссылки StudioMir, которую вернул `episode/target`.
    ///
    /// Поддержаны форматы: `...?ani=53&ep=1` (живой пример Anixart),
    /// `...&anime_id=53`, `/anime/53`, `/anime/53-kanojo-…` (число — начало slug).
    ///
    /// - Returns: id аниме из цифр или `nil`, если в ссылке его нет.
    static func aniId(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                guard aniQueryNames.contains(item.name.lowercased()),
                      let value = item.value,
                      let id = leadingDigits(in: value) else { continue }
                return id
            }
        }

        if let id = leadingDigits(afterAnimeComponentIn: url.path) {
            return id
        }

        // Ссылка может прийти упакованной в другой URL (`?url=…%3Fani%3D53`):
        // после декодирования параметр виден только в строке целиком.
        if let decoded = url.absoluteString.removingPercentEncoding,
           let id = leadingDigits(afterQueryNameIn: decoded) {
            return id
        }

        return nil
    }

    /// Номер серии из ссылки (`ep=`/`episode=`). Парсер оригинала ищет `[&?]ep=(\d+)`.
    private static func episodeNumber(from url: URL) -> Int? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        for item in components.queryItems ?? [] where ["ep", "episode"].contains(item.name.lowercased()) {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let number = Int(value) else { continue }
            return number
        }
        return nil
    }

    /// Первая группа цифр в начале строки: `"53&ep=1"` → `"53"`, `"1-kanojo"` → `"1"`.
    private static func leadingDigits(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }

    /// Id из пути страницы аниме: `/anime/53`, `/animes/53`, `/anime/53-kanojo-…`.
    private static func leadingDigits(afterAnimeComponentIn path: String) -> String? {
        let lowercased = path.lowercased()
        for marker in ["/anime/", "/animes/"] {
            guard let range = lowercased.range(of: marker) else { continue }
            if let id = leadingDigits(in: String(lowercased[range.upperBound...])) {
                return id
            }
        }
        return nil
    }

    /// Id из раскодированной ссылки: `?ani=`/`&ani=`, включая параметры внутри
    /// другого URL (после `removingPercentEncoding`).
    private static func leadingDigits(afterQueryNameIn text: String) -> String? {
        let lowercased = text.lowercased()
        for name in aniQueryNames {
            for separator in ["?", "&"] {
                guard let range = lowercased.range(of: separator + name + "=") else { continue }
                if let id = leadingDigits(in: String(lowercased[range.upperBound...])) {
                    return id
                }
            }
        }
        return nil
    }

    // MARK: - Разрешение ссылки

    /// Получает прямой HLS-поток для серии источника AnixPlayer.
    ///
    /// - Parameters:
    ///   - url: ссылка из `episode/target` (`…/tsmplayer/embed?ani=…&ep=…`).
    ///   - title: заголовок серии для экрана плеера.
    /// - Returns: `.hls` с лучшей доступной дорожкой, `providerName` «AnixPlayer»
    ///   и referer `https://studiomir.club/`.
    /// - Throws: `PlaybackError.resolutionFailed` — если в ссылке нет `ani`, API
    ///   ответил ошибкой или непонятным JSON, у серии нет HLS-ссылки.
    static func resolve(url: URL, title: String) async throws -> PlaybackTarget {
        guard let ani = aniId(from: url) else {
            throw PlaybackError.resolutionFailed("в ссылке studiomir нет идентификатора аниме (ani)")
        }

        let data = try await loadAnimeData(ani: ani)
        let episodes = try decodeEpisodes(from: data)
        guard !episodes.isEmpty else {
            throw PlaybackError.resolutionFailed("studiomir не вернул серии (players.tsm пуст)")
        }

        guard let episode = chooseEpisode(for: episodeNumber(from: url), in: episodes) else {
            throw PlaybackError.resolutionFailed("в ответе studiomir нет подходящей серии")
        }
        guard let stream = streamURL(for: episode) else {
            throw PlaybackError.resolutionFailed("в ответе studiomir нет HLS-ссылки для серии")
        }

        return PlaybackTarget(
            kind: .hls(stream),
            title: title,
            providerName: providerName,
            referer: referer
        )
    }

    // MARK: - Сеть

    /// Запрос к API StudioMir: `ani` из ссылки, `apikey` — хардкод оригинала.
    private static func loadAnimeData(ani: String) async throws -> Data {
        guard var components = URLComponents(string: apiBase) else {
            throw PlaybackError.resolutionFailed("некорректный адрес API studiomir")
        }
        components.queryItems = [
            URLQueryItem(name: "ani", value: ani),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        guard let url = components.url else {
            throw PlaybackError.resolutionFailed("не удалось собрать запрос к API studiomir")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PlaybackError.resolutionFailed("нет связи с studiomir: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.resolutionFailed("studiomir вернул не HTTP-ответ")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlaybackError.resolutionFailed("API studiomir ответил HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw PlaybackError.resolutionFailed("API studiomir вернул пустой ответ")
        }
        return data
    }

    // MARK: - Выбор серии и качества

    /// Серия с номером `number`; если номер неизвестен — из всего списка (то есть
    /// первая серия). Приоритет типов как в оригинальном парсере: `TV`, затем `TR`,
    /// иначе последняя подходящая запись.
    private static func chooseEpisode(for number: Int?, in episodes: [StudioMirEpisode]) -> StudioMirEpisode? {
        let candidates = number.map { value in episodes.filter { $0.episode == value } } ?? episodes
        guard !candidates.isEmpty else { return nil }

        for type in ["TV", "TR"] {
            if let match = candidates.first(where: { $0.type?.uppercased() == type }) {
                return match
            }
        }
        return candidates.last
    }

    /// Лучшая дорожка серии: `2160p` → `1080p` → `720p`, иначе `url` (как «Default»).
    /// Для отсутствующих качеств StudioMir отдаёт пустые строки.
    private static func streamURL(for episode: StudioMirEpisode) -> URL? {
        let variants = [episode.hls?.uhd, episode.hls?.fullHD, episode.hls?.hd, episode.url]
        for variant in variants {
            guard let value = variant?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else { continue }
            return url
        }
        return nil
    }

    // MARK: - Модель ответа

    /// Ответ StudioMir — JSON-массив аниме (живой пример: массив из одного элемента).
    private struct StudioMirAnime: Decodable {
        let players: StudioMirPlayers?
    }

    private struct StudioMirPlayers: Decodable {
        /// Плеер StudioMir: по элементу на каждую серию и тип (`TV`/`TR`).
        let tsm: [StudioMirEpisode]?
    }

    private struct StudioMirEpisode: Decodable {
        let episode: Int?
        let type: String?
        let url: String?
        let hls: StudioMirHls?
    }

    /// Качества StudioMir: ключи `2160p`/`1080p`/`720p`, пустая строка — качества нет.
    private struct StudioMirHls: Decodable {
        let uhd: String?
        let fullHD: String?
        let hd: String?

        enum CodingKeys: String, CodingKey {
            case uhd = "2160p"
            case fullHD = "1080p"
            case hd = "720p"
        }
    }

    private static func decodeEpisodes(from data: Data) throws -> [StudioMirEpisode] {
        do {
            let anime = try JSONDecoder().decode([StudioMirAnime].self, from: data)
            return anime.first?.players?.tsm ?? []
        } catch {
            throw PlaybackError.resolutionFailed("не удалось разобрать ответ studiomir")
        }
    }
}
