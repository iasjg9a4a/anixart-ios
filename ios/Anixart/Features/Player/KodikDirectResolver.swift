import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле — как в APIClient.swift
#endif

/// Готовая нативная ссылка Kodik: страница-источник, качества из `ftor` и лучшее из них.
struct KodikStream: Equatable {
    /// Нормализованный адрес подписанной страницы Kodik (`…/{type}/{id}/{hash}/{quality}`,
    /// без query). Он же — `Referer` запроса к `ftor` и подсказка для экрана плеера.
    let pageURL: URL
    /// Качества из ответа `ftor`: ключ — «360», «480», «720», «1080» (без «p»).
    let qualities: [String: URL]
    /// Лучшее качество по лестнице `1080 > 720 > 480 > 360`.
    let bestQuality: String
    /// Ссылка лучшего качества для нативного `AVPlayer` (`.hls`).
    let bestURL: URL
}

/// Прямой резолв Kodik в HLS — обход WebView-прокси и его ошибки «Error code: ds».
///
/// ## Зачем
///
/// Для Kodik Anixart отдаёт в `episode/target/...` подписанную страницу плеера:
/// `https://kodikplayer.com/seria/175268/<hash>/720p?d=…&s=…&ip=…`. Сейчас iOS-порт
/// открывает её в `WKWebView` через серверный прокси `anixmirai.com/iframe?url=…`,
/// но внутри iframe Kodik отвечает «Error code: ds» (подпись не принимается) —
/// видео не играет. Reference-клиент `Anixapp-Community/anixapp`
/// (`src/native/kodik-direct.ts`) не показывает страницу, а напрямую спрашивает
/// у Kodik ссылки на файлы и играет их нативно; этот резолвер повторяет тот же путь.
///
/// ## Алгоритм (проверен на живом API 24.11.2026)
///
/// 1. Нормализовать подписанную ссылку: **отбросить query** (`d`/`s`/`ip` для `ftor`
///    не нужны) → `https://kodikplayer.com/seria/{id}/{hash}/{quality}`.
/// 2. Разобрать путь `/{type}/{id}/{hash}/{quality}`; поддерживаются типы `seria`,
///    `video`, `movie`, `anime`, а «качество» — как `720p`, так и `720`.
/// 3. `GET https://kodikplayer.com/ftor?type={type}&hash={hash}&id={id}` с заголовками
///    `Referer: <нормализованный URL>`, `Accept: application/json`, браузерным
///    `User-Agent` и таймаутом 20 с. Ответ — JSON
///    `{"links":{"360":[{"src":"…"}],"480":[…],"720":[…]}}` (ключи — качество без «p»;
///    бывает и `1080`).
/// 4. Декодировать `src` каждого качества: готовый `http(s)`/`//`-URL — как есть;
///    URL на CDN Kodik — как есть; иначе — ROT+18 по буквам **внутри регистра**
///    (A-Z и a-z циклично, цифры/символы не меняются) и Base64.
///    Проверено: `Tg9rjO91HLQck29…` → `//cloud2.solodcdn.com/…/720.mp4:hls:manifest.m3u8`.
/// 5. Прогрессивный `.mp4` на CDN Kodik (`solodcdn`, `kodik-storage`, `zerocdn`,
///    `animedia`, `kodik-cdn`) заменить на HLS-манифест `…mp4:hls:manifest.m3u8`:
///    `AVPlayer` играет и mp4, но HLS даёт сегменты и быстрый старт.
/// 6. Отдать `KodikStream`: `qualities`, `bestQuality` по приоритету `1080 > 720 >
///    480 > 360`, `bestURL` — цель `PlaybackKind.hls`.
///
/// ## Что подтверждено живой пробой (24.11.2026, python urllib)
///
/// * `GET kodikplayer.com/ftor?type=seria&hash=48eeb2a7…&id=175268` → `200 application/json`,
///   `links` = ровно `360`/`480`/`720` по одному `src` в каждом, `default: 360`,
///   `type: application/x-mpegURL`.
/// * Декод всех трёх `src` даёт
///   `//cloud2.solodcdn.com/useruploads/<uuid>/<hash>:2026112415/{360,480,720}.mp4:hls:manifest.m3u8`.
/// * Каждый манифест без `Referer`/куки отдаёт `200 application/vnd.apple.mpegurl`
///   и тело `#EXTM3U` с сегментами; первый сегмент (`seg-1-v1-a1.ts`, 1 131 384 байта)
///   тоже отдаётся без заголовков — `206 video/MP2T`. То есть CDN не требует ни
///   `Referer`, ни подписи, и `AVPlayer` сможет забрать сегменты сам.
/// * `episode/target/1/8/1` (фикстура `episode_target.json`) отдаёт ссылку
///   `kodikplayer.com/seria/175268/48eeb2a7…/720p?d=2026112407&s=…&ip=…`; после
///   отбрасывания query она нормализуется в страницу из шага 1.
///
/// ## Что НЕ проверено — только на macOS/устройстве
///
/// * Само воспроизведение `AVPlayer` этих ссылок на iOS (и в RU-сети: доступность
///   `cloud2.solodcdn.com` с устройства не мерялась).
/// * Качество `1080` в `ftor` на живой выборке не встречалось — поддержано по
///   описанию reference-клиента, но реальным ответом не подтверждено.
/// * Варианты ответа, где `src` уже готовый `http`-URL или прогрессивный `.mp4`
///   без HLS, поддержаны кодом, но живьём не встречались.
/// * Живой вызов `ftor` с iOS: сетевой слой (`URLSession`) проверен только на Linux
///   в юнит-тестах без сети; на устройстве запрос не исполнялся.
enum KodikDirectResolver {

    // MARK: - Константы

    /// Имя источника для `PlaybackTarget.providerName` и подписи на экране плеера.
    static let providerName = "Kodik"

    /// Браузерный UA: Kodik — обычный сайт, с пустым/мобильным UA `ftor` может
    /// ответить не-JSON. Тот же UA, с которым проверен живой ответ 24.11.2026.
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /// Эндпоинт прямых ссылок Kodik (reference-клиент: `_endpointUrl = '/ftor'`).
    private static let ftorEndpoint = "https://kodikplayer.com/ftor"

    /// Таймаут запроса к `ftor` — 20 с, как в проверенном python-скрипте.
    private static let requestTimeout: TimeInterval = 20

    /// Типы пути подписанной ссылки Kodik, которые понимает `ftor`.
    private static let knownPageTypes: Set<String> = ["seria", "video", "movie", "anime"]

    /// Лестница предпочтения качества — ключи ответа `ftor` без «p».
    private static let qualityPreference = ["1080", "720", "480", "360"]

    /// Хвост HLS-манифеста Kodik: дописывается прогрессивному `.mp4` на его CDN.
    private static let hlsManifestSuffix = ":hls:manifest.m3u8"

    /// Хосты CDN Kodik. `.mp4` с них — прогрессивный файл, которому предпочитаем HLS.
    private static let streamCDNHostMarkers = [
        "solodcdn", "kodik-storage", "zerocdn", "animedia", "kodik-cdn"
    ]

    /// Хосты, чьи `src` в ответе `ftor` уже приходят готовой ссылкой, а не Base64.
    private static let readyURLHostMarkers = [
        "kodik-storage.com", "solodcdn.com", "zerocdn.com", "animedia.", "kodik-cdn."
    ]

    /// Расширения, которые считаем потоком; иначе `preferPlayableURL` вернёт `nil`.
    private static let streamPathExtensions: Set<String> = ["mp4", "m3u8"]

    // MARK: - Публичный вход

    /// Прямой HLS Kodik для подписанной ссылки из `episode/target`.
    ///
    /// Сеть и разбор максимально «мягкие»: любая ошибка (битая ссылка, отказ Kodik,
    /// не-JSON, пустой список качеств) — это `nil`, а не исключение. Вызывающий код
    /// по `nil` просто остаётся на прежнем пути (WebView-прокси / автоподбор).
    static func resolve(embedURL: URL) async -> KodikStream? {
        guard let pageURL = normalizedEmbedURL(embedURL),
              let identity = parseIdentity(pageURL),
              let requestURL = ftorURL(for: identity) else {
            return nil
        }

        var request = URLRequest(
            url: requestURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Referer нормализованной страницы — как в проверенном python-скрипте
        // (reference-клиент шлёт пустой referrer; здесь повторяем проверенный вариант).
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            let qualities = qualityURLs(fromFtorJSON: data)
            guard let bestQuality = pickBestQuality(qualities),
                  let bestURL = qualities[bestQuality] else {
                return nil
            }
            return KodikStream(
                pageURL: pageURL,
                qualities: qualities,
                bestQuality: bestQuality,
                bestURL: bestURL
            )
        } catch {
            return nil
        }
    }

    // MARK: - Нормализация ссылки

    /// Нормализованная подписанная страница Kodik: `…/{type}/{id}/{hash}/{quality}`.
    ///
    /// Query (`d`, `s`, `ip`) отбрасывается: `ftor` подпись не проверяет, а в `Referer`
    /// нужна именно «чистая» страница. Заодно разворачивается web-прокси Anixart
    /// (`anixmirai.com/iframe?url=…`), чтобы вызывающему коду было достаточно передать
    /// `PlaybackKind.web`-цель как есть.
    ///
    /// - Returns: `nil`, если это не ссылка Kodik с разбираемым путём.
    nonisolated static func normalizedEmbedURL(_ url: URL) -> URL? {
        for candidate in candidatesForEmbed(url) {
            guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = components.host,
                  !host.isEmpty else {
                continue
            }
            components.query = nil
            components.fragment = nil
            components.user = nil
            components.password = nil
            guard let normalized = components.url, parseIdentity(normalized) != nil else {
                continue
            }
            return normalized
        }
        return nil
    }

    /// Разбор пути подписанной страницы: `/{type}/{id}/{hash}/{quality}`.
    ///
    /// Тип — `seria`, `video`, `movie` или `anime`; `id` — только цифры; `hash` —
    /// буквы/цифры (у Kodik это 32-символьный hex); качество — `360p`/`360`/`1080p`
    /// и т.п. Нужны только `type`/`id`/`hash`, но четвёртый сегмент проверяется,
    /// чтобы не спутать страницу Kodik с произвольным URL.
    ///
    /// - Returns: `nil`, если путь не похож на страницу Kodik.
    nonisolated static func parseIdentity(_ url: URL) -> (type: String, id: String, hash: String)? {
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 4 else { return nil }

        let type = segments[0].lowercased()
        let id = segments[1]
        let hash = segments[2]
        guard knownPageTypes.contains(type),
              isASCIIDigits(id),
              isHash(hash),
              isQualitySegment(segments[3]) else {
            return nil
        }
        return (type: type, id: id, hash: hash)
    }

    // MARK: - Декод ссылки из ftor

    /// Декодирует `src` из ответа `ftor` в строку URL.
    ///
    /// Исторически Kodik кодирует ссылки «Base64 после ROT+18»; текущий API может
    /// вернуть и готовый URL. Порядок проверок (он же — в reference-клиенте):
    ///
    /// * `http(s)://…` — уже абсолютная ссылка, как есть;
    /// * `//host/…` — протокол-относительная, дописываем `https:`;
    /// * строка содержит хост CDN Kodik — это уже URL, только без схемы;
    /// * иначе — ROT+18 (буквы внутри регистра) и Base64.
    ///
    /// - Returns: декодированная строка (для Base64 — уже UTF-8 содержимое) либо
    ///   `nil`, если это не ссылка Kodik и Base64 не разбирается.
    nonisolated static func decodeSource(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if readyURLHostMarkers.contains(where: { lowercased.contains($0) }) {
            return trimmed
        }

        let rotated = rotateLetters(trimmed)
        guard let data = base64Decoded(rotated),
              let decoded = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    /// Превращает `src` из `ftor` в проверенный URL потока.
    ///
    /// Схема/хост проверяются (`http`/`https`, домен с точкой), а расширение —
    /// только `mp4`/`m3u8`: готовую страницу Kodik или мусор после неудачного декода
    /// нативное воспроизведение не примет. Прогрессивный `.mp4` на CDN Kodik
    /// превращается в HLS-манифест (`…mp4:hls:manifest.m3u8`).
    ///
    /// - Returns: URL для `AVPlayer` либо `nil`.
    nonisolated static func preferPlayableURL(_ raw: String) -> URL? {
        guard let decoded = decodeSource(raw) else { return nil }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute: String
        let lowercased = trimmed.lowercased()
        if trimmed.hasPrefix("//") {
            absolute = "https:" + trimmed
        } else if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            absolute = trimmed
        } else if lowercased.contains("://") {
            return nil                     // чужая схема (data:, ftp:…) — это не поток
        } else {
            absolute = "https://" + trimmed  // голый хост CDN из ветки «уже URL»
        }

        guard let url = streamURL(absolute) else { return nil }
        return hlsPreferredURL(url, absoluteString: absolute)
    }

    // MARK: - Выбор качества

    /// Лучшее качество по лестнице `1080 > 720 > 480 > 360`.
    ///
    /// Ключи сравниваются терпимо (`"720"` и `"720p"` — одно качество). Если в ответе
    /// нет ни одного качества из лестницы, берётся самое высокое из чисел (например
    /// `240`), чтобы плеер всё-таки открылся.
    ///
    /// - Returns: ключ исходного словаря; `nil` для пустой карты.
    nonisolated static func pickBestQuality(_ map: [String: URL]) -> String? {
        guard !map.isEmpty else { return nil }

        for preference in qualityPreference {
            if let key = map.keys.first(where: { normalizedQuality($0) == preference }) {
                return key
            }
        }

        var best: (quality: Int, key: String)?
        for key in map.keys {
            guard let quality = normalizedQuality(key), let value = Int(quality) else { continue }
            if best == nil || value > best!.quality {
                best = (quality: value, key: key)
            }
        }
        return best?.key
    }

    // MARK: - Варианты качества для плеера

    /// Варианты качества Kodik для меню плеера: `"1080p"`, `"720p"`, `"480p"`…
    ///
    /// Порядок — лучшее первым, ровно по той же лестнице, что у `pickBestQuality`
    /// (`1080 > 720 > 480 > 360`, затем прочие числовые качества по убыванию). Поэтому
    /// `variants(for:).first?.url` всегда равен `stream.bestURL`: меню открывается
    /// на текущем качестве.
    ///
    /// - Parameter stream: разобранный `ftor`-ответ (`KodikStream.qualities`).
    /// - Returns: пустой массив, если в `ftor` не было ни одного качества.
    nonisolated static func variants(for stream: KodikStream) -> [PlaybackVariant] {
        variants(from: stream.qualities)
    }

    /// То же по словарю качеств `ftor` (ключи без «p»: `"360"`, `"720"`…).
    ///
    /// Чистая функция без сети: её проверяют XCTest'ы (`QualityVariantsTests`).
    /// Ключи с «p» и без считаются одним качеством; при дубле остаётся первый по
    /// алфавиту (формат `ftor` фактически уникален, это страховка от ручных словарей).
    nonisolated static func variants(from qualities: [String: URL]) -> [PlaybackVariant] {
        // Сортируем ключи до дедупликации: результат не должен зависеть от порядка
        // обхода словаря (у `Dictionary` он недетерминированный).
        var resolved: [Int: URL] = [:]
        for key in qualities.keys.sorted() {
            guard let quality = normalizedQuality(key), let value = Int(quality) else { continue }
            if resolved[value] == nil {
                resolved[value] = qualities[key]
            }
        }

        return resolved.keys
            .sorted { lhs, rhs in
                let left = qualityPreference.firstIndex(of: String(lhs))
                let right = qualityPreference.firstIndex(of: String(rhs))
                switch (left, right) {
                case let (.some(a), .some(b)): return a < b
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return lhs > rhs
                }
            }
            .compactMap { value in
                guard let url = resolved[value] else { return nil }
                return PlaybackVariant(quality: "\(value)p", url: url)
            }
    }

    // MARK: - Ответ ftor

    /// Качества из JSON-ответа `ftor` (`{links: {quality: [{src: …}]}}`).
    ///
    /// Разбор терпимый: отсутствующие/пустые `links`, `null` вместо массива, элементы
    /// без `src`, нечисловые качества — просто пропускаются. Так изменение формата
    /// Kodik не роняет показ, а лишь заставляет остаться на web-плеере.
    ///
    /// Метод чистый (без сети), чтобы разбор ответа можно было покрыть тестами.
    nonisolated static func qualityURLs(fromFtorJSON data: Data) -> [String: URL] {
        guard !data.isEmpty,
              let response = try? JSONDecoder().decode(FtorResponse.self, from: data) else {
            return [:]
        }

        var qualities: [String: URL] = [:]
        for (rawQuality, group) in response.links {
            guard let quality = normalizedQuality(rawQuality) else { continue }
            for item in group.items {
                guard let raw = item.src?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty,
                      let url = preferPlayableURL(raw) else {
                    continue
                }
                qualities[quality] = url
                break
            }
        }
        return qualities
    }

    // MARK: - Сеть

    /// URL запроса к `ftor` для разобранной страницы.
    private static func ftorURL(for identity: (type: String, id: String, hash: String)) -> URL? {
        guard var components = URLComponents(string: ftorEndpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "type", value: identity.type),
            URLQueryItem(name: "hash", value: identity.hash),
            URLQueryItem(name: "id", value: identity.id)
        ]
        return components.url
    }

    // MARK: - Разбор путей

    /// Варианты URL для нормализации: исходный и, если это прокси Anixart, вложенный.
    private static func candidatesForEmbed(_ url: URL) -> [URL] {
        var candidates = [url]
        if let unwrapped = unwrappedProxyURL(url) {
            candidates.append(unwrapped)
        }
        return candidates
    }

    /// Ссылка из web-прокси Anixart `anixmirai.com/iframe?url=<encoded>`.
    private static func unwrappedProxyURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?
                  .first(where: { $0.name == "url" })?
                  .value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let inner = URL(string: raw),
              inner.host != nil else {
            return nil
        }
        return inner
    }

    /// Строка — только цифры (id Kodik и сегмент качества).
    private static func isASCIIDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// Строка — только латинские буквы и цифры (хеш Kodik).
    private static func isASCIIAlphanumeric(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57)     // 0-9
                || (value >= 65 && value <= 90)     // A-Z
                || (value >= 97 && value <= 122)    // a-z
        }
    }

    /// Хеш серии Kodik: буквы/цифры, не короче 8 символов (живые значения — 32 hex).
    private static func isHash(_ value: String) -> Bool {
        value.count >= 8 && isASCIIAlphanumeric(value)
    }

    /// Сегмент качества: `720p`, `1080p`, `720`, `480`… (2–4 цифры, суффикс `p` не важен).
    private static func isQualitySegment(_ segment: String) -> Bool {
        var digits = segment.lowercased()
        if digits.hasSuffix("p") {
            digits.removeLast()
        }
        return (2...4).contains(digits.count) && isASCIIDigits(digits)
    }

    /// Качество в виде ключа без «p» (`"720p"` → `"720"`); `nil` для нечисловых ключей.
    private static func normalizedQuality(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("p") {
            value.removeLast()
        }
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        return value
    }

    // MARK: - Декод ROT+18 + Base64

    /// ROT+18 по буквам внутри регистра: `A-Z` и `a-z` циклично, остальное без изменений.
    private static func rotateLetters(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 65 && value <= 90 {
                result.unicodeScalars.append(Unicode.Scalar((value - 65 + 18) % 26 + 65)!)
            } else if value >= 97 && value <= 122 {
                result.unicodeScalars.append(Unicode.Scalar((value - 97 + 18) % 26 + 97)!)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Base64 с дозаполнением padding до длины, кратной 4.
    private static func base64Decoded(_ text: String) -> Data? {
        var padded = text
        let remainder = padded.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: padded)
    }

    // MARK: - Ссылки CDN

    /// Проверенный URL потока: http(s), домен с точкой, расширение `mp4`/`m3u8`.
    private static func streamURL(_ absolute: String) -> URL? {
        guard let url = URL(string: absolute),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              host.contains("."),
              streamPathExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return url
    }

    /// Прогрессивный `.mp4` на CDN Kodik заменяется на HLS-манифест того же файла.
    ///
    /// `:hls:manifest.m3u8` — виртуальный суффикс Kodik: тот же файл отдаётся
    /// сегментами как HLS. Уже готовый HLS и `.mp4` с чужих хостов возвращаются
    /// без изменений, а query (если он есть) сохраняется после суффикса.
    private static func hlsPreferredURL(_ url: URL, absoluteString: String) -> URL {
        guard url.pathExtension.lowercased() == "mp4",
              let host = url.host?.lowercased(),
              streamCDNHostMarkers.contains(where: { host.contains($0) }) else {
            return url
        }

        // Суффикс вставляется до query, чтобы не сломать подпись/токен в ссылке.
        var base = absoluteString
        var query = ""
        if let index = base.firstIndex(of: "?") {
            query = String(base[index...])
            base = String(base[..<index])
        }
        return URL(string: base + hlsManifestSuffix + query) ?? url
    }
}

// MARK: - Ответ ftor (Codable, терпимый к формату)

/// `{"links": {"360": [{"src": "…", "type": "…"}], "720": […]}, …}`.
///
/// Все ошибки формы проглатываются: неизвестные поля игнорируются, `links` может
/// отсутствовать, а качества — содержать пустые/битые элементы. Резолверу нужен
/// только первый рабочий `src` каждого качества.
private struct FtorResponse: Decodable {
    let links: [String: FtorQuality]

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            links = [:]
            return
        }
        links = (try? container.decodeIfPresent([String: FtorQuality].self, forKey: .links)) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case links
    }
}

/// Одно качество: массив ссылок; `null`/не-массив считается пустым списком.
private struct FtorQuality: Decodable {
    let items: [FtorItem]

    init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            items = []
            return
        }
        var items: [FtorItem] = []
        while !container.isAtEnd {
            // `FtorItem` не бросает исключений; `break` — страховка, чтобы никогда
            // не зациклиться, если форма ответа всё-таки окажется неожиданной.
            guard let item = try? container.decode(FtorItem.self) else { break }
            items.append(item)
        }
        self.items = items
    }
}

/// Элемент списка ссылок: нужен только `src`.
private struct FtorItem: Decodable {
    let src: String?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            src = nil
            return
        }
        src = try? container.decodeIfPresent(String.self, forKey: .src)
    }

    enum CodingKeys: String, CodingKey {
        case src
    }
}
