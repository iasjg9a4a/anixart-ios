import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле — как в APIClient.swift
#endif

/// Нативная HLS-ссылка AniLibria из подписанной страницы `iframe.php`.
///
/// Для источников Libria/Liberty Anixart отдаёт не поток, а HTML-страницу
/// `https://anixart.libria.fun/public/iframe.php?id=1243&ep=1&d=…&s=…&ip=…`
/// (`iframe == false`). Оригинальное Android-приложение (`AniLibriaParser`) не показывает
/// её в WebView, а повторяет разбор из `docs/PLAYERS.md` §4:
///
/// 1. из query достаются `id` (релиз AniLibria) и `ep` (номер серии);
/// 2. GET `https://anilibria.top/api/v1/anime/releases/{id}` (`analysis/strings.txt:198306`) —
///    `episodes[]`, у серии с `ordinal == ep` берутся поля `hls_1080`/`hls_720`/`hls_480`,
///    побеждает лучшее непустое качество;
/// 3. фолбэк, если API не дал ссылку: GET самой подписанной страницы и разбор Playerjs —
///    `file:[{"id":"s1","file":"[480p]https://…,[720p]https://…"}, …]` (в оригинале то же
///    самое регулярками `"s".*?"file":"(.*?)"` и `\[([0-9]*p)](.*?)(,|$)`);
/// 4. результат — `PlaybackTarget(kind: .hls(…), providerName: "AniLibria", referer: nil)`.
///
/// Подпись `d`/`s`/`ip` привязана к IP, а `d` обновляется каждый час, поэтому ссылку
/// нужно запрашивать перед каждым показом (`episode/target`), а не кэшировать.
///
/// ## Что подтверждено (живая проба 24.11.2026, python urllib)
/// * `episode/target/1562/218/1` (источник «Libria») →
///   `iframe.php?id=1243&ep=1&d=2026112405&s=…&ip=…`, `iframe: false`.
/// * `GET anilibria.top/api/v1/anime/releases/1243` → `200 application/json`,
///   `episodes[0].ordinal == 1`; `hls_720` =
///   `https://cache-rfn.libria.fun/videos/media/ts/1243/1/720/6093620d37ca071c1630cae4bcac79a0.m3u8
///   ?countryIso=RU&isAuthorized=0&isWithVideoAds=1…`, `hls_480` есть, `hls_1080` — `null`.
/// * `episode/target/20306/413/1` (источник «Liberty») → `iframe.php?id=10312&ep=1`;
///   у релиза 10312 `hls_1080` непустой — выбирается 1080p. Оба URL отдают `200` и `#EXTM3U`.
/// * `GET` подписанного `iframe.php` → `200 text/html` с `new Playerjs({… file:[{…}]})`;
///   ссылки `cache.libria.fun/…m3u8?clientIp=…&countryIso=RU…` тоже `200` и `#EXTM3U`.
///
/// ## Что НЕ проверено — на устройстве (см. `docs/PLAYERS.md` §12)
/// * Доступен ли `anilibria.top/api/v1/...` с iOS и играет ли `AVPlayer`
///   `cache*.libria.fun` — гео-ограничение отдаёт CDN (параметр `countryIso` в m3u8).
/// * Нужны ли `Referer`/`User-Agent` для `cache.libria.fun`: по пробам без них `200`,
///   но заголовки запросов медиаплеера менять нечем — это отдельная задача плеера.
/// * Вариант `episodes[i].player.list` в живом ответе не встречался — поддержан по
///   описанию задачи как запасной формат, на реальных данных не проверен.
enum AniLibriaResolver {

    // MARK: - Константы

    /// Имя источника для UI и логов (`PlaybackTarget.providerName`).
    static let providerName = "AniLibria"

    /// База API AniLibria: `…/anime/releases/{id}` (`analysis/strings.txt:198306`).
    private static let apiBase = "https://anilibria.top/api/v1/anime/releases/"

    /// Десктопный UA, как у OkHttp-парсеров оригинала (`docs/PLAYERS.md` §1.1): API и
    /// подписанная страница его не проверяют, но с пустым UA часть CDN режет запросы.
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"

    /// Таймаут API — 30 с, как в `AniLibriaParser` (`docs/PLAYERS.md` §4).
    private static let apiTimeout: TimeInterval = 30

    /// Таймаут подписанной страницы: HTML небольшой, 20 с с запасом.
    private static let pageTimeout: TimeInterval = 20

    /// Порядок предпочтения качеств: 1080p → 720p → 480p.
    private static let qualityPreference = [1080, 720, 480]

    // MARK: - Публичный вход

    /// Достаёт HLS-ссылку серии Libria и отдаёт её нативному плееру.
    ///
    /// Сначала пробует API AniLibria, затем — Playerjs самой подписанной страницы.
    /// Первая успешная попытка выигрывает; если обе не дали ссылку, бросает
    /// `PlaybackError.resolutionFailed` с причинами обеих попыток.
    ///
    /// - Parameters:
    ///   - url: подписанный URL серии из `episode/target` (`iframe == false`).
    ///   - title: заголовок для экрана плеера.
    /// - Throws: `PlaybackError.resolutionFailed`, если HLS получить не удалось.
    static func resolve(url: URL, title: String) async throws -> PlaybackTarget {
        guard let host = url.host?.lowercased(), isLibriaHost(host) else {
            throw PlaybackError.resolutionFailed("ссылка ведёт не на AniLibria: \(url.host ?? "—")")
        }
        guard let reference = reference(from: url) else {
            throw PlaybackError.resolutionFailed("в ссылке AniLibria нет id релиза или номера серии")
        }

        let apiAttempt = await hlsURL(fromAPI: reference)
        if let hls = apiAttempt.url {
            return target(hls, title: title)
        }

        let pageAttempt = await hlsURL(fromPage: url, episode: reference.episode)
        if let hls = pageAttempt.url {
            return target(hls, title: title)
        }

        let failures = [apiAttempt.failure, pageAttempt.failure]
            .compactMap { $0 }
            .joined(separator: "; ")
        throw PlaybackError.resolutionFailed(
            failures.isEmpty ? "AniLibria не вернула HLS" : "AniLibria: \(failures)"
        )
    }

    // MARK: - Ссылка серии

    /// Id релиза AniLibria и номер серии из query подписанной ссылки.
    struct Reference: Equatable {
        let releaseId: Int
        let episode: Int
    }

    /// Разбор `id=…&ep=…` из query `iframe.php`.
    ///
    /// - Returns: `nil`, если хотя бы одного параметра нет или он не число.
    static func reference(from url: URL) -> Reference? {
        guard let releaseId = intValue(queryValue("id", in: url)),
              let episode = intValue(queryValue("ep", in: url)) else {
            return nil
        }
        return Reference(releaseId: releaseId, episode: episode)
    }

    // MARK: - Основной путь: API AniLibria

    /// HLS-ссылка лучшего качества из JSON `anime/releases/{id}`.
    ///
    /// Живой формат (проверено 24.11.2026): `{"episodes":[{"ordinal":1,
    /// "hls_480":"https://cache-rfn.libria.fun/…m3u8?…", "hls_720":"…", "hls_1080":null}]}`.
    /// Дополнительно поддержан вариант `episodes[i].player.list` со ссылками и качествами.
    ///
    /// Метод чистый (без сети), чтобы разбор можно было покрыть тестами на фикстуре.
    static func hlsURL(fromReleaseJSON data: Data, episode: Int) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let episodes = root["episodes"] as? [[String: Any]] else {
            return nil
        }

        // Номер серии в ответе — `ordinal`; `sort_order` — запасное поле того же смысла.
        let node = episodes.first { intValue($0["ordinal"]) == episode }
            ?? episodes.first { intValue($0["sort_order"]) == episode }
        guard let node else { return nil }

        for quality in qualityPreference {
            if let raw = node["hls_\(quality)"] as? String,
               let url = streamURL(raw) {
                return url
            }
        }

        if let player = node["player"] as? [String: Any],
           let list = player["list"] as? [Any],
           let url = bestHLS(fromPlayerList: list) {
            return url
        }
        return nil
    }

    // MARK: - Фолбэк: Playerjs в подписанной странице

    /// HLS-ссылка из HTML `iframe.php`.
    ///
    /// Страница содержит `new Playerjs({id:"anilibriaPlayer", … file:[{"id":"s1",
    /// "file":"[480p]https:\/\/cache.libria.fun\/…m3u8,…,[720p]…"}, …]})`.
    /// Сначала массив `file:[…]` разбирается как JSON и берётся серия `s{ep}`
    /// (иначе — по индексу), затем — регулярки оригинального парсера на случай
    /// другого формата страницы. Метод чистый (без сети), чтобы его можно было тестировать.
    static func hlsURL(fromPlayerjsHTML html: String, episode: Int) -> URL? {
        guard let file = playerjsFile(from: html, episode: episode) else { return nil }
        let unescaped = file
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
        if let best = bestHLS(fromQualityList: unescaped) {
            return best
        }
        return firstPlainURL(in: unescaped)
    }

    // MARK: - Сеть

    /// Результат одной попытки: найденная ссылка либо причина, по которой её нет.
    private struct Lookup {
        let url: URL?
        let failure: String?
    }

    /// Результат `GET`: данные либо причина, по которой их нет.
    private struct FetchResult {
        let data: Data?
        let failure: String?
    }

    /// GET API релиза и выбор HLS нужной серии.
    private static func hlsURL(fromAPI reference: Reference) async -> Lookup {
        guard let url = URL(string: apiBase + String(reference.releaseId)) else {
            return Lookup(url: nil, failure: "некорректный id релиза \(reference.releaseId)")
        }
        let response = await fetch(url, accept: "application/json", timeout: apiTimeout)
        guard let data = response.data else {
            return Lookup(url: nil, failure: "API: \(response.failure ?? "нет ответа")")
        }
        guard let hls = hlsURL(fromReleaseJSON: data, episode: reference.episode) else {
            return Lookup(url: nil, failure: "API: у серии \(reference.episode) нет HLS")
        }
        return Lookup(url: hls, failure: nil)
    }

    /// GET подписанной страницы и разбор Playerjs.
    private static func hlsURL(fromPage url: URL, episode: Int) async -> Lookup {
        let response = await fetch(url, accept: "text/html,application/xhtml+xml", timeout: pageTimeout)
        guard let data = response.data else {
            return Lookup(url: nil, failure: "страница: \(response.failure ?? "нет ответа")")
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let hls = hlsURL(fromPlayerjsHTML: html, episode: episode) else {
            return Lookup(url: nil, failure: "страница: Playerjs не содержит HLS")
        }
        return Lookup(url: hls, failure: nil)
    }

    /// GET с заголовками AniLibria; сетевые и HTTP-ошибки не бросают исключение,
    /// а возвращаются как причина — фолбэк должен получить шанс в любом случае.
    private static func fetch(_ url: URL, accept: String, timeout: TimeInterval) async -> FetchResult {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return FetchResult(data: nil, failure: "некорректный HTTP-ответ")
            }
            guard (200..<300).contains(http.statusCode) else {
                return FetchResult(data: nil, failure: "HTTP \(http.statusCode)")
            }
            guard !data.isEmpty else {
                return FetchResult(data: nil, failure: "пустой ответ")
            }
            return FetchResult(data: data, failure: nil)
        } catch {
            return FetchResult(data: nil, failure: error.localizedDescription)
        }
    }

    // MARK: - Разбор ответа API

    /// Лучшая ссылка из `player.list` (у части релизов AniLibria ссылки лежат там).
    private static func bestHLS(fromPlayerList list: [Any]) -> URL? {
        var best: (quality: Int, url: URL)?
        for item in list {
            guard let candidate = candidate(fromPlayerListItem: item) else { continue }
            if let current = best {
                if candidate.quality > current.quality {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best?.url
    }

    /// Кандидат качества из элемента `player.list`: строка `[720p]https://…` или объект
    /// с полями `quality`/`height` и `file`/`url`/`hls`/`src`.
    private static func candidate(fromPlayerListItem item: Any) -> (quality: Int, url: URL)? {
        if let raw = item as? String {
            return qualityAndURL(from: raw)
        }
        guard let object = item as? [String: Any] else { return nil }
        let quality = intValue(object["quality"]) ?? intValue(object["height"]) ?? 0
        let raw = (object["file"] as? String)
            ?? (object["url"] as? String)
            ?? (object["hls"] as? String)
            ?? (object["src"] as? String)
        guard let raw, let url = streamURL(raw) else { return nil }
        return (quality, url)
    }

    /// Качество и ссылка из одной записи вида `[720p]https://…` (или просто из ссылки).
    private static func qualityAndURL(from raw: String) -> (quality: Int, url: URL)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let values = regexMatches(#"^\[(\d{3,4})p\]\s*(.+)$"#, in: trimmed).first,
           values.count == 2,
           let quality = Int(values[0]),
           let url = streamURL(values[1]) {
            return (quality, url)
        }
        guard let url = streamURL(trimmed) else { return nil }
        return (0, url)
    }

    // MARK: - Разбор Playerjs

    /// Строка `file` нужной серии из Playerjs.
    private static func playerjsFile(from html: String, episode: Int) -> String? {
        if let file = playerjsFileFromArray(from: html, episode: episode) {
            return file
        }

        // Регулярки оригинального разбора (`docs/PLAYERS.md` §4): `"s<ep>".*?"file":"…"`.
        let byEpisode = #""s\#(episode)".*?"file":"(.*?)""#
        let firstFile = #""file":"(.*?)""#
        for pattern in [byEpisode, firstFile] {
            if let value = regexMatches(pattern, in: html).first?.first, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Массив `file:[…]` из Playerjs, разобранный как JSON, и строка нужной серии.
    ///
    /// JSON надёжнее регулярок: ссылки в нём экранированы (`\/`) и содержат запятые,
    /// а качеств у серии несколько.
    private static func playerjsFileFromArray(from html: String, episode: Int) -> String? {
        var searchStart = html.startIndex
        while let range = html.range(of: "file:", range: searchStart..<html.endIndex) {
            var index = range.upperBound
            while index < html.endIndex, html[index].isWhitespace {
                index = html.index(after: index)
            }
            if index < html.endIndex, html[index] == "[",
               let array = balancedJSONArray(from: index, in: html),
               let file = fileString(fromJSONArray: array, episode: episode) {
                return file
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// Вырезает JSON-массив `[…]`, начиная с `start`, с учётом строк и экранирования.
    private static func balancedJSONArray(from start: String.Index, in text: String) -> String? {
        guard start < text.endIndex, text[start] == "[" else { return nil }
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Строка `file` серии из распарсенного Playerjs-массива.
    private static func fileString(fromJSONArray json: String, episode: Int) -> String? {
        guard let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        let entry = entries.first { ($0["id"] as? String) == "s\(episode)" }
            ?? entries.dropFirst(max(episode - 1, 0)).first
        guard let entry else { return nil }

        if let file = entry["file"] as? String {
            return file
        }
        if let files = entry["file"] as? [String], !files.isEmpty {
            return files.joined(separator: ",")
        }
        return nil
    }

    /// Лучшее качество из строки Playerjs `[480p]https://…,[720p]https://…`.
    private static func bestHLS(fromQualityList list: String) -> URL? {
        var best: (quality: Int, url: URL)?
        for values in regexMatches(#"\[(\d{3,4})p\]\s*([^,\[]+)"#, in: list) {
            guard values.count == 2,
                  let quality = Int(values[0]),
                  let url = streamURL(values[1]) else {
                continue
            }
            if let current = best {
                if quality > current.quality {
                    best = (quality, url)
                }
            } else {
                best = (quality, url)
            }
        }
        return best?.url
    }

    /// Первая http(s)-ссылка в тексте — запасной путь, если качеств в формате `[720p]` нет.
    private static func firstPlainURL(in text: String) -> URL? {
        for values in regexMatches(#"(https?://[^\s,"\[\]]+)"#, in: text) {
            if let raw = values.first, let url = streamURL(raw) {
                return url
            }
        }
        return nil
    }

    // MARK: - Мелочи

    /// Хосты, которые разбирает `AniLibriaParser` (`docs/PLAYERS.md` §1.1).
    private static func isLibriaHost(_ host: String) -> Bool {
        host.contains("libria") || host.contains("anilib")
    }

    /// Абсолютная http(s)-ссылка или `nil`, если строка не похожа на поток.
    private static func streamURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// Целевой объект для нативного плеера: HLS, без Referer (CDN его не требует).
    private static func target(_ url: URL, title: String) -> PlaybackTarget {
        PlaybackTarget(kind: .hls(url), title: title, providerName: providerName, referer: nil)
    }

    /// Значение query-параметра: сначала через `URLComponents`, затем регуляркой —
    /// `URLComponents` возвращает `nil` на невалидном процентном кодировании.
    private static func queryValue(_ name: String, in url: URL) -> String? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value,
           !value.isEmpty {
            return value
        }
        return regexMatches("[?&]\(name)=(\\d+)", in: url.absoluteString).first?.first
    }

    /// Целое из значения query (`String`) или из JSON-поля (`NSNumber`/`String`).
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Все совпадения регулярки: для каждого — строки захваченных групп (без всей подстроки).
    private static func regexMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let string = text as NSString
        let range = NSRange(location: 0, length: string.length)
        return expression.matches(in: text, range: range).map { result in
            (1..<result.numberOfRanges).map { index in
                let match = result.range(at: index)
                return match.location == NSNotFound ? "" : string.substring(with: match)
            }
        }
    }
}

// MARK: - Подключение

// Вызывается из PlayerView (или ReleaseViewModel) перед показом, когда сервер отдал
// `iframe == false`, а URL ведёт на Libria (`anixart.libria.fun`):
//
//     if episode.iframe != true,
//        VideoProvider.detect(sourceName: source.name, url: url) == .libria,
//        let url = URL(string: episode.url ?? "") {
//         let target = try await AniLibriaResolver.resolve(url: url, title: episode.displayName)
//         playback = target              // .hls → NativePlayerView / AVPlayer
//     }
//
// Ошибки — `PlaybackError.resolutionFailed` с готовым русским текстом: их можно
// показывать в `PlayerPhase.failed` как есть. Signed `iframe.php` в WKWebView — запасной
// путь (реклама Playerjs + VAST), но нативный HLS предпочтительнее: контроль качества.
