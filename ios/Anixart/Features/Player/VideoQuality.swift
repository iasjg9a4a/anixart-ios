import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif
import SwiftUI

// MARK: - Вариант качества

/// Один вариант качества HLS-потока.
///
/// Для HLS качество задаётся master-плейлистом: каждый вариант — отдельный
/// медиа-плейлист с тем же видео в другом разрешении. Плееру отдаётся `url`
/// выбранного варианта, а не исходная ссылка. `auto` — единственный вариант,
/// когда master-плейлиста нет: играем поток как есть, а качество подбирает
/// AVFoundation.
struct VideoQualityVariant: Identifiable, Equatable {
    /// Идентификатор варианта. Совпадает с меткой: в меню один пункт на качество,
    /// а сохранённый выбор хранится именно меткой («1080p», «720p», «auto»…).
    let id: String

    /// Подпись для меню выбора качества.
    let label: String

    /// Ссылка на медиа-плейлист конкретного качества (для `auto` — исходный поток).
    let url: URL

    /// `BANDWIDTH` из `#EXT-X-STREAM-INF` в бит/с. `nil`, если тег его не указал.
    let bandwidth: Int?

    init(id: String, label: String, url: URL, bandwidth: Int? = nil) {
        self.id = id
        self.label = label
        self.url = url
        self.bandwidth = bandwidth
    }

    /// Вариант «auto»: вариантов в плейлисте нет, играем исходный поток.
    static func auto(for url: URL) -> VideoQualityVariant {
        VideoQualityVariant(id: "auto", label: "auto", url: url)
    }
}

// MARK: - Ошибки

/// Почему не удалось получить список качеств.
enum VideoQualityError: LocalizedError, Equatable {
    /// Сервер ответил не HTTP-ответом.
    case invalidResponse
    /// HTTP-код вне диапазона 2xx.
    case http(Int)
    /// Тело плейлиста не прочиталось как UTF-8.
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Не удалось получить список качеств"
        case .http(let code):
            return "Список качеств недоступен (HTTP \(code))"
        case .decoding:
            return "Не удалось разобрать master-плейлист"
        }
    }
}

// MARK: - Выбор качества

/// Выбор качества HLS-плеера: разбор master-плейлиста, запоминание выбора
/// и меню для toolbar.
///
/// Зачем отдельный тип: мобильный плеер не должен знать ни про формат
/// master-плейлиста, ни про то, где хранится выбор. Схема работы:
/// 1. при открытии прямого HLS-потока — `variants(from:)`, получаем список качеств;
/// 2. если пользователь выбирал качество раньше — `preferred(in:)` находит его
///    среди вариантов (сохранённая ссылка не годится: подписанные URL живут
///    ограниченное время, поэтому в `UserDefaults` лежит только метка);
/// 3. по выбору — `remember(_:)`, а в `AVPlayer` уходит `variant.url`.
///
/// Загрузка — обычный `URLSession` с мобильным User-Agent Safari: те же заголовки,
/// что и у основного потока, иначе часть CDN (RuTube, Libria) отдаёт плейлист
/// только браузерным клиентам.
enum VideoQualitySelector {

    // MARK: - Константы

    /// Ключ, под которым в `UserDefaults` лежит метка выбранного качества.
    static let qualityDefaultsKey = "anixart.video.quality"

    /// User-Agent мобильного Safari — как у `PlayerWebView`, который открывает
    /// HTML-плееры Anixart.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Сколько ждём master-плейлист: он маленький, а плеер не должен висеть.
    private static let requestTimeout: TimeInterval = 15

    // MARK: - Загрузка

    /// Скачивает master-плейлист и возвращает доступные варианты качества.
    ///
    /// Если ссылка ведёт не на master-плейлист (в теле нет `#EXT-X-STREAM-INF`),
    /// возвращается один вариант `auto` с исходным URL — такой поток играет
    /// `AVPlayer`, сам выбирая качество по сети.
    ///
    /// - Throws: `VideoQualityError`, если сервер ответил ошибкой или отдал
    ///   нечитаемый плейлист; транспортные ошибки `URLSession` пробрасываются как есть.
    static func variants(from masterPlaylistURL: URL) async throws -> [VideoQualityVariant] {
        var request = URLRequest(
            url: masterPlaylistURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VideoQualityError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VideoQualityError.http(http.statusCode)
        }
        guard let playlist = String(data: data, encoding: .utf8) else {
            throw VideoQualityError.decoding
        }

        let variants = parse(playlist: playlist, baseURL: masterPlaylistURL)
        store(variants)
        return variants
    }

    // MARK: - Разбор плейлиста

    /// Разбирает текст плейлиста без сети — отдельно от `variants(from:)`,
    /// чтобы логику можно было проверить на сохранённом master-плейлисте.
    ///
    /// Вариант описывается парой строк: `#EXT-X-STREAM-INF:...` с атрибутами
    /// (`RESOLUTION=1920x1080`, `BANDWIDTH=…`) и следующей непустой строкой —
    /// относительным или абсолютным URL медиа-плейлиста. Одинаковые качества
    /// из разных CDN (RuTube отдаёт по два зеркала на качество) схлопываются
    /// в один пункт меню — остаётся зеркало с большим битрейтом.
    static func parse(playlist: String, baseURL: URL) -> [VideoQualityVariant] {
        guard playlist.contains("#EXT-X-STREAM-INF") else {
            // Медиа-плейлист или вообще не HLS: список качеств не нужен.
            return [.auto(for: baseURL)]
        }

        var parsed: [(variant: VideoQualityVariant, side: Int, bandwidth: Int)] = []
        var pendingAttributes: [String: String]?
        var index = 0

        for rawLine in playlist.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let rawAttributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                pendingAttributes = attributes(in: rawAttributes)
                continue
            }

            // После тега идёт ровно одна строка с URL; остальные строки — теги.
            guard let attributes = pendingAttributes, !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            pendingAttributes = nil

            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            let bandwidth = intValue(attributes["BANDWIDTH"])
                ?? intValue(attributes["AVERAGE-BANDWIDTH"])
            let resolution = resolution(from: attributes["RESOLUTION"])
            let side = resolution.map { max($0.width, $0.height) } ?? 0
            let label = qualityLabel(
                side: side,
                height: resolution?.height,
                bandwidth: bandwidth,
                index: index
            )
            index += 1

            let variant = VideoQualityVariant(id: label, label: label, url: url, bandwidth: bandwidth)
            parsed.append((variant, side, bandwidth ?? 0))
        }

        guard !parsed.isEmpty else { return [.auto(for: baseURL)] }

        // Сверху — лучшее качество; при равном разрешении — больший битрейт.
        let sorted = parsed.sorted { lhs, rhs in
            if lhs.side != rhs.side { return lhs.side > rhs.side }
            return lhs.bandwidth > rhs.bandwidth
        }

        var seen = Set<String>()
        let variants = sorted.compactMap { entry -> VideoQualityVariant? in
            seen.insert(entry.variant.label).inserted ? entry.variant : nil
        }
        return variants.isEmpty ? [.auto(for: baseURL)] : variants
    }

    // MARK: - Сохранённый выбор

    /// Сохранённая пользователем метка качества; `nil`, если выбора ещё нет.
    static func rememberedLabel() -> String? {
        let value = UserDefaults.standard.string(forKey: qualityDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    /// Вариант из переданного списка, соответствующий сохранённому выбору.
    ///
    /// Возвращает `nil`, если пользователь ничего не выбирал или сохранённого
    /// качества в этом плейлисте нет (например, оно пропало) — тогда плеер
    /// играет поток по умолчанию.
    static func preferred(in variants: [VideoQualityVariant]) -> VideoQualityVariant? {
        guard let label = rememberedLabel() else { return nil }
        return match(label: label, in: variants)
    }

    /// Предпочтительный вариант из последнего разобранного master-плейлиста.
    ///
    /// Метка берётся из `UserDefaults`; параметр `id` — запасной вариант на
    /// случай, если сохранённого выбора нет. Требует, чтобы `variants(from:)`
    /// уже был вызван в этой сессии: сохранённая ссылка намеренно не
    /// используется — подписанные URL истекают, а плейлист перезапрашивается.
    ///
    /// Если список вариантов уже под рукой, проще и надёжнее `preferred(in:)`.
    static func preferred(_ id: String?) -> VideoQualityVariant? {
        let requested = rememberedLabel() ?? id?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requested = requested, !requested.isEmpty else { return nil }
        return match(label: requested, in: cachedVariants())
    }

    /// Запоминает выбор пользователя: в `UserDefaults` кладётся только метка.
    static func remember(_ variant: VideoQualityVariant) {
        UserDefaults.standard.set(variant.label, forKey: qualityDefaultsKey)
    }

    // MARK: - Кэш последнего плейлиста

    /// Варианты, которые использует `preferred(_:)`: он не может сам сходить
    /// в сеть (синхронный), а список приходит из `variants(from:)`.
    private static let cacheLock = NSLock()
    private static var lastParsedVariants: [VideoQualityVariant] = []

    private static func store(_ variants: [VideoQualityVariant]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        lastParsedVariants = variants
    }

    private static func cachedVariants() -> [VideoQualityVariant] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lastParsedVariants
    }

    // MARK: - Атрибуты тега

    /// Разбирает список атрибутов `KEY=VALUE,KEY="VALUE, С ЗАПЯТОЙ"`.
    ///
    /// Запятые внутри кавычек (например, в `CODECS`) не разделяют атрибуты,
    /// поэтому строка режется вручную, а не через `components(separatedBy:)`.
    private static func attributes(in line: String) -> [String: String] {
        var pieces: [String] = []
        var current = ""
        var isQuoted = false

        for character in line {
            if character == "\"" {
                isQuoted.toggle()
                current.append(character)
            } else if character == ",", !isQuoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)

        var result: [String: String] = [:]
        for piece in pieces {
            guard let separator = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<separator])
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            var value = String(piece[piece.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// `RESOLUTION=1920x1080` → ширина и высота кадра.
    private static func resolution(from value: String?) -> (width: Int, height: Int)? {
        guard let value = value else { return nil }
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func intValue(_ value: String?) -> Int? {
        guard let value = value, !value.isEmpty else { return nil }
        return Int(value)
    }

    /// Подпись качества по разрешению — как у Android-парсера RuTube
    /// (`docs/PLAYERS.md`, §5): ориентируемся на большую сторону кадра.
    /// Без `RESOLUTION` остаётся битрейт, без него — порядковый номер.
    private static func qualityLabel(side: Int, height: Int?, bandwidth: Int?, index: Int) -> String {
        switch side {
        case 3840...:
            return "2160p"
        case 2560...:
            return "1440p"
        case 1920...:
            return "1080p"
        case 1280...:
            return "720p"
        case 854...:
            return "480p"
        case 640...:
            return "360p"
        default:
            break
        }
        if let height = height, height > 0 {
            return "\(height)p"
        }
        if let bandwidth = bandwidth, bandwidth > 0 {
            return "\(bandwidth / 1000) кбит/с"
        }
        return "Вариант \(index + 1)"
    }

    /// Совпадение по метке; запасной вариант — по `id` (равен метке, но
    /// сравнение по id оставлено на случай ручного создания вариантов).
    private static func match(label: String, in variants: [VideoQualityVariant]) -> VideoQualityVariant? {
        variants.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
            ?? variants.first { $0.id == label }
    }
}

// MARK: - Меню

/// Компактное меню выбора качества для toolbar плеера.
///
/// Показывает список вариантов из master-плейлиста, отмечает текущее качество
/// галочкой и сообщает о выборе через `onSelect`. Стиль — акцентный, как у
/// остальных элементов плеера; вариантов обычно 2–5, поэтому меню не мешает.
struct VideoQualityMenu: View {
    /// Варианты качества из `VideoQualitySelector.variants(from:)`.
    let variants: [VideoQualityVariant]

    /// Текущее качество; `nil` — качество ещё не выбрано (автоматическое).
    var current: VideoQualityVariant? = nil

    /// Выбор пользователя. Плеер должен перезапустить воспроизведение
    /// с `variant.url` и запомнить выбор через `VideoQualitySelector.remember(_:)`.
    let onSelect: (VideoQualityVariant) -> Void

    var body: some View {
        if variants.isEmpty {
            // Нечего предлагать (поток без master-плейлиста) — не занимаем toolbar.
            EmptyView()
        } else {
            Menu {
                ForEach(variants) { variant in
                    Button {
                        onSelect(variant)
                    } label: {
                        if isCurrent(variant) {
                            Label(variant.label, systemImage: "checkmark")
                        } else {
                            Text(variant.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .tint(Theme.accent)
            .accessibilityLabel("Качество видео")
        }
    }

    private func isCurrent(_ variant: VideoQualityVariant) -> Bool {
        guard let current = current else { return false }
        return variant.id == current.id || variant.label == current.label
    }
}
