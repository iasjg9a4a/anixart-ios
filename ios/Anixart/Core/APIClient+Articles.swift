import Foundation

// MARK: - Статьи
//
// Контракт снят с живого beta-API 24.11.2026:
//   POST search/feed/{page}             с телом {"query": ""} — лента статей;
//   GET  article/236888                 — полная статья;
//   GET  article/comment/all/{a_id}/{page} — комментарии статьи.
//
// Пути `article/all/{page}` в API нет: GET отвечает HTTP 400 с пустым телом,
// POST отдаёт `{"code":0,"content":[]}` (фильтр без параметров ничего не находит).
// В APK beta-11 такого пути тоже нет — список статей берётся из `search/feed/{page}`
// (см. analysis/endpoints.txt и ROADMAP.md, строка «Статьи/лента»).
//
// Важно про модель: у статьи НЕТ полей title/description/image/tags. Текст и картинки
// лежат в `payload.blocks` (редакторские блоки paragraph/header/quote/media).
// Поэтому модель хранит реальные ключи сервера, а `title`, `description`, `image`
// и `tags` — вычисляемые свойства поверх блоков.

// MARK: - Модель статьи

/// Статья канала. Один и тот же объект приходит в `search/feed/{page}`,
/// `channel/{c_id}/article/all/{page}` и `article/{a_id}`.
struct Article: Decodable, Identifiable, ArticleBodyProviding {
    let id: Int

    var channel: ArticleChannel?
    /// Автор статьи из поля `author` (для статей канала обычно `null`).
    var author: ProfileBrief?
    /// Тело статьи: редакторские блоки.
    var payload: ArticlePayload?

    /// Голос текущего пользователя: 0 — не голосовал, 1 / -1 — голос.
    var vote: Int?
    /// Статья, которую эта запись репостит. Вложенность обрывается на `ArticleRepost`:
    /// структура не может хранить себя через Optional («recursive value type»).
    var repostArticle: ArticleRepost?

    var commentCount: Int?
    var repostCount: Int?
    var voteCount: Int?

    /// Unix-время в секундах.
    var creationDate: Int?
    var lastUpdateDate: Int?

    var isSigned: Bool?
    var isPinned: Bool?
    var isMuted: Bool?
    var isDeleted: Bool?
    var containsRepostArticle: Bool?
    var hasDeleteEnforcement: Bool?
    /// Закреплённый «популярный» комментарий — та же форма, что у комментариев релиза.
    var popularComment: ReleaseComment?

    enum CodingKeys: String, CodingKey {
        case id, channel, author, payload, vote
        case repostArticle = "repost_article"
        case commentCount = "comment_count"
        case repostCount = "repost_count"
        case voteCount = "vote_count"
        case creationDate = "creation_date"
        case lastUpdateDate = "last_update_date"
        case isSigned = "is_signed"
        case isPinned = "is_pinned"
        case isMuted = "is_muted"
        case isDeleted = "is_deleted"
        case containsRepostArticle = "contains_repost_article"
        case hasDeleteEnforcement = "has_delete_enforcement"
        case popularComment = "popular_comment"
    }

    /// Профиль автора. В JSON ключ называется `author`, в старом Android-API —
    /// `profile`; здесь оставлен алиас для удобства экранов.
    var profile: ProfileBrief? { author }
}

/// Зарепощённая статья из поля `repost_article`. Сервер присылает её полным
/// объектом статьи, но раскрывать репосты рекурсивно не нужно, поэтому
/// вложенность здесь обрывается (структура не может содержать себя через Optional).
struct ArticleRepost: Decodable, Identifiable, ArticleBodyProviding {
    let id: Int
    var channel: ArticleChannel?
    var author: ProfileBrief?
    var payload: ArticlePayload?
    var vote: Int?
    var commentCount: Int?
    var repostCount: Int?
    var voteCount: Int?
    var creationDate: Int?
    var lastUpdateDate: Int?
    var popularComment: ReleaseComment?

    enum CodingKeys: String, CodingKey {
        case id, channel, author, payload, vote
        case commentCount = "comment_count"
        case repostCount = "repost_count"
        case voteCount = "vote_count"
        case creationDate = "creation_date"
        case lastUpdateDate = "last_update_date"
        case popularComment = "popular_comment"
    }

    var profile: ProfileBrief? { author }
}

/// Канал, в котором опубликована статья (`channel` внутри статьи).
struct ArticleChannel: Decodable, Identifiable {
    let id: Int
    var title: String?
    var description: String?
    var cover: String?
    var avatar: String?

    var articleCount: Int?
    var subscriberCount: Int?
    var permission: Int?

    var isBlog: Bool?
    var isVerified: Bool?
    var isSubscribed: Bool?
    var isMuted: Bool?
    var isDeleted: Bool?
    var isCommentingEnabled: Bool?
    var isArticleSuggestionEnabled: Bool?

    var creationDate: Int?
    var lastUpdateDate: Int?
    var blogProfileID: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, description, cover, avatar, permission
        case articleCount = "article_count"
        case subscriberCount = "subscriber_count"
        case isBlog = "is_blog"
        case isVerified = "is_verified"
        case isSubscribed = "is_subscribed"
        case isMuted = "is_muted"
        case isDeleted = "is_deleted"
        case isCommentingEnabled = "is_commenting_enabled"
        case isArticleSuggestionEnabled = "is_article_suggestion_enabled"
        case creationDate = "creation_date"
        case lastUpdateDate = "last_update_date"
        case blogProfileID = "blog_profile_id"
    }

    var displayTitle: String { title?.isEmpty == false ? title! : "Канал" }
}

/// Тело статьи: версионированный набор блоков редактора.
struct ArticlePayload: Decodable {
    /// Время последнего изменения в миллисекундах (`payload.time`, не путать с `last_update_date`).
    var time: Int?
    var blocks: [ArticleBlock]?
    var version: String?
    var blockCount: Int?

    enum CodingKeys: String, CodingKey {
        case time, blocks, version
        case blockCount = "block_count"
    }
}

/// Один блок статьи. `type` и `name` сейчас совпадают: paragraph, header, quote,
/// media, list, embed, delimiter. Набор полей `data` зависит от типа, поэтому
/// разбираем его лениво и без падений на неизвестных блоках.
struct ArticleBlock: Decodable {
    var id: String?
    var name: String?
    var type: String?
    var data: ArticleBlockData?

    enum CodingKeys: String, CodingKey {
        case id, name, type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        data = try? container.decodeIfPresent(ArticleBlockData.self, forKey: .data)
    }
}

struct ArticleBlockData: Decodable {
    var text: String?
    var level: Int?
    var caption: String?
    var alignment: String?
    var itemCount: Int?
    var items: [ArticleMediaItem]?

    enum CodingKeys: String, CodingKey {
        case text, level, caption, alignment, items
        case itemCount = "item_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Все поля опциональны: блоки list/embed/delimiter приходят с другим набором
        // полей, и один незнакомый блок не должен ронять разбор всей статьи.
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        level = try? container.decodeIfPresent(Int.self, forKey: .level)
        caption = try? container.decodeIfPresent(String.self, forKey: .caption)
        alignment = try? container.decodeIfPresent(String.self, forKey: .alignment)
        itemCount = try? container.decodeIfPresent(Int.self, forKey: .itemCount)
        items = try? container.decodeIfPresent([ArticleMediaItem].self, forKey: .items)
    }
}

struct ArticleMediaItem: Decodable {
    var id: String?
    var url: String?
    var hash: String?
    var width: Int?
    var height: Int?
}

// MARK: - Вычисляемые поля статьи

/// Текст статьи лежит в `payload.blocks`, поэтому заголовок, описание, картинка
/// и теги вычисляются одинаково и для полной статьи, и для репоста.
protocol ArticleBodyProviding {
    var payload: ArticlePayload? { get }
    var channel: ArticleChannel? { get }
}

extension ArticleBodyProviding {
    var blocks: [ArticleBlock] { payload?.blocks ?? [] }

    /// Заголовок: первый блок `header`; если его нет — первый абзац,
    /// затем название канала.
    var title: String {
        let header = plainText(type: "header")
        if !header.isEmpty { return header }

        let paragraph = plainText(type: "paragraph")
        if !paragraph.isEmpty { return paragraph }

        if let title = channel?.title, !title.isEmpty { return title }
        return "Без названия"
    }

    /// Короткое описание: первый абзац статьи (HTML вычищен).
    var description: String? {
        let paragraph = plainText(type: "paragraph")
        if !paragraph.isEmpty { return paragraph }

        let quote = plainText(type: "quote")
        return quote.isEmpty ? nil : quote
    }

    /// Картинка статьи: первый файл из первого блока `media`.
    var image: String? {
        for block in blocks where block.type == "media" {
            if let url = block.data?.items?.compactMap({ $0.url }).first, !url.isEmpty {
                return url
            }
        }
        return nil
    }

    var imageURL: URL? {
        guard let raw = image else { return nil }
        let url = URL(string: raw)
        return url?.scheme == nil ? nil : url
    }

    /// Теги статьи. Отдельного поля в API нет, поэтому собираем хэштеги из текста блоков.
    var tags: [String]? {
        var seen = Set<String>()
        var result: [String] = []

        for block in blocks {
            guard let raw = block.data?.text, !raw.isEmpty else { continue }
            for word in ArticleText.plain(raw).split(whereSeparator: { $0.isWhitespace }) {
                guard word.hasPrefix("#"), word.count > 1 else { continue }
                let tag = word.trimmingCharacters(in: CharacterSet(charactersIn: "#,.!?;:()[]{}«»\"'"))
                guard tag.count > 1, seen.insert(tag.lowercased()).inserted else { continue }
                result.append(tag)
            }
        }

        return result.isEmpty ? nil : result
    }

    private func plainText(type: String) -> String {
        for block in blocks where block.type == type {
            guard let raw = block.data?.text else { continue }
            let text = ArticleText.normalized(ArticleText.plain(raw))
            if !text.isEmpty { return text }
        }
        return ""
    }
}

// MARK: - Разбор текста блоков

/// Блоки приходят как HTML-фрагменты (`<b>`, `<a href>`, `&#x1f56f;`), а показывать
/// их нужно простым текстом: вычищаем теги и раскрываем сущности.
enum ArticleText {
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let namedEntities: [(String, String)] = [
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")
    ]

    private static func decodeEntities(_ raw: String) -> String {
        var text = raw
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let tail = rest[rest.index(after: ampersand)...]
            guard tail.hasPrefix("#"), let semicolon = tail.firstIndex(of: ";") else {
                result += "&"
                rest = tail
                continue
            }

            let body = tail[tail.index(after: tail.startIndex)..<semicolon]
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body, radix: 10)
            }

            if let value = value, let scalar = UnicodeScalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "&" + String(tail[..<semicolon]) + ";"
            }
            rest = tail[tail.index(after: semicolon)...]
        }
        result += rest
        return result
    }
}

// MARK: - Запросы

extension APIClient {
    private struct ArticleResponse: Decodable {
        let code: Int
        let article: Article?
    }

    /// Ответ `search/feed/{page}`: снаружи общий конверт поиска, внутри — страница статей.
    private struct FeedSearchResponse: Decodable {
        let code: Int
        let articles: Paged<Article>?
    }

    private struct FeedSearchBody: Encodable {
        let query: String
    }

    /// Лента статей (общий список без входа).
    ///
    /// Сервер не отдаёт `GET article/all/{page}` (HTTP 400), поэтому реально используемый
    /// публичный список — `POST search/feed/{page}`; без входа он работает с пустым
    /// запросом и отдаёт статьи по 25 на страницу. Проверено 24.11.2026.
    func articles(page: Int = 1) async throws -> Paged<Article> {
        let body = try encoder.encode(FeedSearchBody(query: ""))
        let value: FeedSearchResponse = try await request("search/feed/\(max(page - 1, 0))", method: "POST", body: body)
        try check(value.code)
        guard let articles = value.articles else { throw APIError.empty }
        return articles
    }

    /// Статьи канала. Публичный и проверенный список: 20 статей на страницу.
    func channelArticles(channelId: Int, page: Int = 1) async throws -> Paged<Article> {
        let value: Paged<Article> = try await request("channel/\(channelId)/article/all/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Одна статья по идентификатору. Для удалённой/недоступной статьи сервер отвечает
    /// `{"code":2,"article":null}` — `check(2)` превращает это в `APIError.api(2)`.
    func article(id: Int) async throws -> Article {
        let value: ArticleResponse = try await request("article/\(id)")
        try check(value.code)
        guard let article = value.article else { throw APIError.empty }
        return article
    }

    /// Комментарии статьи. Форма элементов совпадает с комментариями релиза
    /// (`ReleaseComment`), плюс лишние ключи `type`, `article`, `parent_comment_id`,
    /// которые Codable игнорирует. Читаются без входа.
    func articleComments(articleId: Int, page: Int = 1) async throws -> Paged<ReleaseComment> {
        let value: Paged<ReleaseComment> = try await request("article/comment/all/\(articleId)/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }
}
