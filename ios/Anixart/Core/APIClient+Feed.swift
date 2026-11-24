import Foundation

// MARK: - Лента и поиск по ленте
//
// Разбор APK (11-beta-3, `network/api/FeedApi`) даёт точные контракты:
//   feed/(latest)                        → GET  feed/latest            → LatestArticleResponse { code, articleId }
//   feed(int page, Long?, int, String)   → GET  feed/all/{page}        → PageableResponse<Article>
//   latestArticles(int page, String)     → GET  feed/latest/all/{page} → PageableResponse<Article>
//   search/feed/{page}                   → POST {"query": …}           → FeedSearchResponse
//
// `feed/latest`, `feed/all/{page}` и `feed/latest/all/{page}` без токена отвечают
// `200 {"code":401}` (зафиксировано в analysis/fixtures/feed_*.json и живой пробой
// 24.11.2026), поэтому проверяем вход заранее.
// `feed/latest/all/{page}` с токеном проверен живым запросом 24.11.2026: 25 статей.
// `search/feed` доступен без входа и проверен живым запросом 24.11.2026.

extension APIClient {
    /// Последняя статья ленты. Требует входа.
    ///
    /// Возвращает `articleId` из ответа `feed/latest`: сервер отдаёт не список,
    /// а `{"code": 0, "articleId": …}` (класс `LatestArticleResponse` в APK).
    func feedLatest() async throws -> Int? {
        try requireFeedToken()
        let value: LatestArticleResponse = try await request("feed/latest")
        try check(value.code)
        return value.articleId
    }

    /// Поток ленты, страница `feed/all/{page}`. Требует входа.
    ///
    /// В APK метод `FeedApi.feed` возвращает `PageableResponse<Article>`,
    /// поэтому ответ — обычная страница статей, без обёртки `FeedResponse`.
    func feed(page: Int = 1) async throws -> Paged<ArticleBrief> {
        try requireFeedToken()
        let value: Paged<ArticleBrief> = try await request("feed/all/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Постраничная лента статей: `feed/latest/all/{page}`. Требует входа.
    ///
    /// В APK — `FeedApi.latestArticles(int page, String token)` →
    /// `GET feed/latest/all/{page}` → `PageableResponse<Article>`.
    /// Живой ответ 24.11.2026: с токеном — `code: 0` и 25 полных статей
    /// (те же ключи, что у `feed/all`: `id`, `channel`, `payload`,
    /// `creation_date`, `comment_count`, `vote_count`); без токена —
    /// HTTP 200 и `{"code": 401}`, поэтому вход проверяется заранее.
    /// Возвращаем полный `Article`, а не `ArticleBrief`: заголовок статьи
    /// лежит в `payload.blocks` и вычисляется в `Article.title`.
    func latestArticles(page: Int = 1) async throws -> Paged<Article> {
        try requireFeedToken()
        let value: Paged<Article> = try await request("feed/latest/all/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Поиск по ленте (`search/feed/{page}`, POST). Доступен без входа.
    ///
    /// Живой ответ на `{"query":"аниме"}` отсюда: `code`, `tags`, `channels`,
    /// `blogs`, `articles`. Первые три ключа сейчас приходят `null`, `articles` —
    /// страница статей. В APK все четыре поля объявлены как `PageableResponse`
    /// (`tags` — от строк, `channels`/`blogs` — от каналов).
    func searchFeed(query: String, page: Int = 1) async throws -> FeedResponse {
        let body = try encoder.encode(QueryBody(query: query))
        let value: FeedResponse = try await request("search/feed/\(max(page - 1, 0))", method: "POST", body: body)
        try check(value.code)
        return value
    }

    private func requireFeedToken() throws {
        guard let token = TokenStore.shared.token, !token.isEmpty else {
            throw APIError.unauthorized
        }
    }

    // MARK: - История и прогресс
    //
    // Эти два эндпоинта лежат в файле ленты по договорённости с остальными правками
    // ветки: отдельного `APIClient+History.swift` не заводим, а `APIClient+Actions.swift`
    // занят записывающими действиями списков. Оба требуют входа.

    /// Убрать релиз из истории просмотров: `history/delete/{r_id}`.
    ///
    /// В SDK (`release/history.ts`) — `GET`, тело ответа — `IHistoryResponse`,
    /// то есть только `{"code": …}`. Живым вызовом НЕ проверялось: запрос меняет
    /// состояние аккаунта, а разрешены были только чтения. Вызывать после явного
    /// действия пользователя (свайп «удалить из истории»).
    func historyDelete(releaseId: Int) async throws {
        let value: ServerCode = try await request("history/delete/\(releaseId)")
        if let code = value.code { try check(code) }
    }

    /// Отмеченные эпизоды по списку релизов: `episode/watched?release_ids=…`.
    ///
    /// В APK — `EpisodeApi.episodeWatched(List<Long> releaseIds, String token)`:
    /// список id уходит query-параметром через запятую. Живой ответ 24.11.2026:
    /// `{"code":0,"sources":[{"release_id":18591,"source_id":7,"positions":[11,12]}]}`;
    /// без `release_ids` сервер отвечает HTTP 200 с ПУСТЫМ телом (не JSON),
    /// поэтому параметр обязателен — пустой список не отправляем.
    func episodeWatched(releaseIds: [Int]) async throws -> [WatchedSource] {
        guard !releaseIds.isEmpty else { return [] }
        let ids = releaseIds.map(String.init).joined(separator: ",")
        let value: EpisodeWatchedResponse = try await request("episode/watched?release_ids=\(ids)")
        try check(value.code)
        return value.sources ?? []
    }
}

// MARK: - Тело запроса

/// JSON-тело поиска: сервер ждёт `{"query": "…"}`. `SearchBody` в APIClient.swift приватный.
private struct QueryBody: Encodable {
    let query: String
}

// MARK: - Ответы

/// Ответ `search/feed/{page}`.
///
/// Все четыре ключа в APK описаны как `PageableResponse` и могут быть `null`.
/// Сейчас сервер заполняет только `articles`.
struct FeedResponse: Decodable {
    let code: Int
    let tags: Paged<String>?
    let channels: Paged<ChannelBrief>?
    let blogs: Paged<ChannelBrief>?
    let articles: Paged<ArticleBrief>?
}

/// Статья в ленте (элемент `PageableResponse<Article>`).
///
/// У статьи в ленте нет готовых `title`/`image`: заголовок и картинка лежат
/// внутри `payload.blocks`, поэтому здесь они необязательные.
/// Реально приходят `id`, `channel`, `creation_date`, `comment_count`, `vote_count`.
struct ArticleBrief: Decodable, Identifiable {
    let id: Int
    let title: String?
    let image: String?
    let channel: ChannelBrief?
    let creationDate: Int?
    let commentCount: Int?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, image, channel
        case creationDate = "creation_date"
        case commentCount = "comment_count"
        case voteCount = "vote_count"
    }
}

/// Канал (или блог) ленты: элемент `PageableResponse<Channel>`.
struct ChannelBrief: Decodable, Identifiable {
    let id: Int
    let title: String?
    let avatar: String?
    let cover: String?
    let isBlog: Bool?
    let subscriberCount: Int?

    /// Минимальная картинка канала: аватар, иначе обложка.
    var image: String? { avatar ?? cover }

    enum CodingKeys: String, CodingKey {
        case id, title, avatar, cover
        case isBlog = "is_blog"
        case subscriberCount = "subscriber_count"
    }
}

/// Ответ `feed/latest`: `{"code":0,"articleId":…}`.
///
/// У `LatestArticleResponse` в APK нет `@JsonProperty` (в отличие от `Article`/`Channel`,
/// где snake_case задан явно), поэтому основной ключ — camelCase; snake_case
/// поддержан запасным вариантом на случай смены сериализатора.
private struct LatestArticleResponse: Decodable {
    let code: Int
    let articleId: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case articleIdCamel = "articleId"
        case articleIdSnake = "article_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        if let id = try container.decodeIfPresent(Int.self, forKey: .articleIdCamel) {
            articleId = id
        } else {
            articleId = try container.decodeIfPresent(Int.self, forKey: .articleIdSnake)
        }
    }
}

// MARK: - Прогресс просмотров

/// Просмотренные серии одного источника — элемент ответа `episode/watched`.
///
/// Живой ответ 24.11.2026: `{"release_id": 18591, "source_id": 7,
/// "positions": [11, 12]}` — источник и уже отмеченные позиции серий.
struct WatchedSource: Decodable {
    let releaseId: Int
    let sourceId: Int?
    let positions: [Int]?

    enum CodingKeys: String, CodingKey {
        case positions
        case releaseId = "release_id"
        case sourceId = "source_id"
    }
}

/// Ответ `episode/watched`: `{"code": 0, "sources": [WatchedSource]}`.
private struct EpisodeWatchedResponse: Decodable {
    let code: Int
    let sources: [WatchedSource]?
}
