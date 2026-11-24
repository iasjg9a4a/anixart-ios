import Foundation

/// Хостинг видео-вставки на странице релиза (опенинги, трейлеры, клипы и т.п.).
enum ReleaseVideoHosting: String {
    case youtube
    case vk
    case rutube
    /// Ролик лежит на Sibnet (`video.sibnet.ru/shell.php?videoid=…`).
    /// Открывается общим плеером: `PlayerView` сам поднимает Sibnet нативно
    /// через `SibnetResolver` (в `playbackTarget` провайдер помечен «Sibnet»).
    case sibnet
    case other

    static func detect(url: URL?, hosting: String?) -> ReleaseVideoHosting {
        let rawHosting = (hosting ?? "").lowercased()
        let host = (url?.host ?? "").lowercased()

        if rawHosting.contains("youtube") || host.contains("youtube") || host.contains("youtu.be") {
            return .youtube
        }
        if rawHosting.contains("vk") || host.contains("vk.com") || host.contains("vkvideo") {
            return .vk
        }
        if rawHosting.contains("rutube") || host.contains("rutube") {
            return .rutube
        }
        if rawHosting.contains("sibnet") || host.contains("sibnet") {
            return .sibnet
        }
        return .other
    }
}

/// Хостинг видео приходит объектом `{id, name, icon}` (проверено живым API:
/// YouTube id=2, ВКонтакте id=3), но встречались и строковые формы — декодируем терпимо.
struct VideoHostingRef: Codable, Hashable {
    var id: Int?
    var name: String?
    var icon: String?

    init(id: Int? = nil, name: String? = nil, icon: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self.id = nil
            self.name = raw
            self.icon = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon
    }
}

struct VideoCategoryRef: Codable, Hashable {
    let id: Int
    var name: String?
}

/// Одно видео на странице релиза (`GET video/release/{releaseId}`).
struct ReleaseVideo: Codable, Identifiable {
    let id: Int
    var releaseId: Int?
    var title: String?
    var image: String?
    var url: String?
    var playerURL: String?
    var hosting: VideoHostingRef?
    var category: VideoCategoryRef?
    var timestamp: Int?
    var favoritesCount: Int?
    var isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, image, url, hosting, category, timestamp
        case releaseId = "release"
        case playerURL = "player_url"
        case favoritesCount = "favorites_count"
        case isFavorite = "is_favorite"
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return category?.name ?? "Видео"
    }

    var hostingKind: ReleaseVideoHosting {
        ReleaseVideoHosting.detect(url: URL(string: url ?? ""), hosting: hosting?.name)
    }

    /// Готовая цель для плеера: YouTube — через iframe-API, остальное — через
    /// `player_url` (VK/RuTube дают embed-страницу) или обычную ссылку.
    var playbackTarget: PlaybackTarget? {
        switch hostingKind {
        case .youtube:
            guard let player = playerURL ?? url, let videoId = Self.youtubeID(from: player) ?? Self.youtubeID(from: url ?? "") else {
                return nil
            }
            return PlaybackTarget(
                kind: .youtube(videoId: videoId),
                title: displayTitle,
                providerName: "YouTube",
                referer: URL(string: "https://www.youtube.com/")
            )
        case .vk:
            guard let raw = playerURL ?? url, let page = URL(string: raw) else { return nil }
            return PlaybackTarget(
                kind: .web(page),
                title: displayTitle,
                providerName: "VK",
                referer: URL(string: "https://vk.com/")
            )
        case .rutube:
            guard let raw = playerURL ?? url, let page = URL(string: raw) else { return nil }
            return PlaybackTarget(
                kind: .web(page),
                title: displayTitle,
                providerName: "RuTube",
                referer: URL(string: "https://rutube.ru/")
            )
        case .sibnet:
            // Как и остальные HTML-плееры — стартуем с web-цели: `PlayerView`
            // попробует нативный резолв (`SibnetResolver`) и оставит WebView,
            // только если не получилось. `providerName` — ключ этого апгрейда
            // (`preparePlayback` ищет «sibnet» в имени провайдера).
            guard let raw = playerURL ?? url, let page = URL(string: raw) else { return nil }
            return PlaybackTarget(
                kind: .web(page),
                title: displayTitle,
                providerName: "Sibnet",
                referer: URL(string: "https://video.sibnet.ru/")
            )
        case .other:
            guard let raw = playerURL ?? url, let page = URL(string: raw) else { return nil }
            return PlaybackTarget(
                kind: .web(page),
                title: displayTitle,
                providerName: "Видео",
                referer: nil
            )
        }
    }

    /// Достаёт id YouTube из watch/embed/shorts/youtu.be-ссылок.
    static func youtubeID(from raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        let host = (url.host ?? "").lowercased()
        if host.contains("youtu.be") {
            let id = url.pathComponents.dropFirst().first
            return id?.isEmpty == false ? id : nil
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return v
        }
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "v" }),
           parts.indices.contains(index + 1) {
            let id = parts[index + 1]
            return id.isEmpty ? nil : id
        }
        return nil
    }
}

struct ReleaseVideoBlock: Codable {
    var category: VideoCategoryRef?
    var videos: [ReleaseVideo]?
}

struct ReleaseVideosResponse: Decodable {
    let code: Int
    let blocks: [ReleaseVideoBlock]?
    let lastVideos: [ReleaseVideo]?

    enum CodingKeys: String, CodingKey {
        case code, blocks
        case lastVideos = "last_videos"
    }
}

/// Официальная площадка, где релиз доступен легально (`release/streaming/platform/{id}`).
struct StreamingPlatform: Codable, Identifiable {
    let id: Int
    var name: String?
    var icon: String?
    var url: String?
    var position: Int?

    var displayName: String { name?.isEmpty == false ? name! : "Площадка" }
    var linkURL: URL? {
        guard let raw = url, let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }
}

struct StreamingPlatformsResponse: Decodable {
    let code: Int
    let content: [StreamingPlatform]?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case code, content
        case totalCount = "total_count"
    }
}
