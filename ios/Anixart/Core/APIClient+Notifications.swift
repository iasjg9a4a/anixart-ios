import Foundation

// MARK: - Уведомления
//
// Контракт снят с APK 11-beta-3: интерфейс `network/api/NotificationApi`
// (classes3.dex). Все 20 его методов помечены Retrofit-аннотацией `@GET` —
// включая «изменяющие» `read`, `delete/all` и `*/delete/{id}`; последний
// параметр каждого метода — `String token` (уходит query-параметром `?token=`).
// Аннотации распарсены из dex, это не догадка по сходству путей:
//
//   all(int page, String token)              GET notification/all/{page}              → PageableResponse<ProfileNotification>
//   count(String token)                      GET notification/count                   → NotificationCountResponse { code, count }
//   read(String token)                       GET notification/read                    → Response { code }
//   deleteAll(String token)                  GET notification/delete/all              → Response { code }
//   deleteFriendNotification(long id, …)     GET notification/friend/delete/{id}      → Response { code }
//   deleteEpisodeNotification(long id, …)    GET notification/episode/delete/{id}     → Response { code }
//   deleteReleaseCommentNotification(…)      GET notification/releaseComment/delete/{id}
//   deleteCollectionCommentNotification(…)   GET notification/collectionComment/delete/{id}
//   deleteMyCollectionCommentNotification(…) GET notification/my/collection/comment/delete/{id}
//   deleteArticleNotification(long id, …)    GET notification/article/delete/{id}
//   deleteArticleCommentNotification(…)      GET notification/articleComment/delete/{id}
//   deleteMyArticleCommentNotification(…)    GET notification/my/article/comment/delete/{id}
//   deleteRelatedReleaseNotification(…)      GET notification/related/release/delete/{id}
//
// Отдельного «общего» удаления `notification/delete/{id}` в API НЕТ: путь
// зависит от типа уведомления, а тип приходит в самом элементе (поле `type`).
//
// Живые пробы 24.11.2026 (аккаунт <test-login>, вход form-urlencoded, HTTP 200):
//   • GET notification/count?token=… → {"code":0,"count":0}
//   • GET notification/all/1?token=… → {"code":0,"content":[],"total_count":0,
//                                       "total_page_count":0,"current_page":0}
//     (`current_page` в ответе сервера нулевой — сервер считает страницы с 0;
//     клиент, как и весь `APIClient`, — с 1)
//   • без токена `notification/count` отвечает 200 {"code":401}
//     (analysis/fixtures/notification_count.json) — это `APIError.unauthorized`.
//   • read/delete/all и `*/delete/{id}` живьём НЕ вызывались: меняют состояние.
// У аккаунта 0 уведомлений, поэтому форма элемента ленты живым ответом не
// подтверждена — она восстановлена по Jackson-аннотациям классов уведомлений
// в APK (см. `NotificationItem`).

extension APIClient {
    /// Объединённая лента уведомлений (`notification/all/{page}`). Требует входа.
    ///
    /// Страницы в приложении нумеруются с единицы, у сервера — с нуля: живой
    /// ответ на `all/1` вернул `current_page: 0`, а в APK `NotificationsState.page`
    /// стартует с `0` и все notification-ленты грузятся с ним. Поэтому в путь
    /// уходит `page - 1` — как и в остальных методах `APIClient`.
    ///
    /// Пустой `content` — нормальный ответ (у тестового аккаунта он всегда пуст).
    func notifications(page: Int = 1) async throws -> Paged<NotificationItem> {
        let value: Paged<NotificationItem> = try await request("notification/all/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Количество непрочитанных уведомлений (`notification/count`). Требует входа.
    ///
    /// В `APIClient` уже есть `notificationCount()` с тем же запросом; здесь —
    /// имя из задачи, реализация общая. Живой ответ: `{"code":0,"count":0}`.
    func unreadCount() async throws -> Int {
        try await notificationCount()
    }

    /// Пометить все уведомления прочитанными (`notification/read`). В APK — `@GET`.
    ///
    /// Живьём не вызывалось (меняет состояние). Ответ — `{"code": …}`;
    /// ненулевой код (`401` — нет входа) превращается в `APIError` через `check`.
    func markAllRead() async throws {
        let value: ServerCode = try await request("notification/read")
        if let code = value.code { try check(code) }
    }

    /// Удалить все уведомления (`notification/delete/all`). В APK — `@GET`.
    ///
    /// Живьём не вызывалось (меняет состояние).
    func deleteAll() async throws {
        let value: ServerCode = try await request("notification/delete/all")
        if let code = value.code { try check(code) }
    }

    /// Удалить одно уведомление. Требует входа.
    ///
    /// Общего пути `notification/delete/{id}` нет: в APK девять методов
    /// `notification/{тип}/delete/{id}`, по одному на каждое значение `type`.
    /// Поэтому тип передаётся явно — иначе адрес запроса не построить.
    func delete(id: Int, type: NotificationItem.Kind) async throws {
        let value: ServerCode = try await request("\(type.deletePath)/\(id)")
        if let code = value.code { try check(code) }
    }

    /// Удалить конкретное уведомление из ленты — тип берётся из его поля `type`.
    ///
    /// Если тип неизвестен (сервер добавил новый, модель его не знает),
    /// бросаем `APIError.badURL`: собрать путь удаления невозможно.
    func delete(_ notification: NotificationItem) async throws {
        guard let type = notification.kind else { throw APIError.badURL }
        try await delete(id: notification.id, type: type)
    }
}

// MARK: - Модель уведомления

/// Элемент объединённой ленты `notification/all/{page}`.
///
/// В API это полиморфный объект: строковое поле `type` — дискриминатор
/// (Jackson `@JsonTypeInfo(use = NAME, property = "type")` в APK), остальные
/// поля зависят от типа. Все поля, кроме `id`, опциональны.
///
/// Из-за того, что у аккаунта 0 уведомлений, форма не проверена живым ответом.
/// Она восстановлена по классам APK (Jackson-аннотации `@JsonProperty`):
///
///   type = friend            → by_profile (профиль), status (0 — заявка, 1 — принята)
///   type = episode           → episode { name, release }
///   type = releaseComment    → comment { id, message, profile, is_spoiler, release }, parentComment
///   type = collectionComment → comment { …, collection }, parentComment
///   type = articleComment    → comment { …, article }, parentComment
///   type = myCollection      → collection_comment { … }
///   type = myArticle         → article_comment { … }
///   type = article           → article { id, creation_date, last_update_date, … }
///   type = relatedRelease    → release
///
/// Полезная нагрузка `article`/`collection` не моделируется (нужна только
/// навигация по id, а id есть в самих comment/notification). `timestamp`
/// сервер отдаёт в миллисекундах, `id` — long (в iOS-модели `Int`).
struct NotificationItem: Decodable, Identifiable {
    let id: Int

    /// Тип уведомления: `friend`, `episode`, `releaseComment`, `collectionComment`,
    /// `myCollection`, `article`, `articleComment`, `myArticle`, `relatedRelease`.
    var type: String?
    var timestamp: Int?

    /// `is_new` — уведомление новое, то есть непрочитанное.
    var isNew: Bool?
    var isPushed: Bool?

    /// Релиз уведомления: верхнеуровневый (`relatedRelease`), из `episode.release`
    /// либо из `comment.release` (`releaseComment`).
    var release: Release?
    /// Комментарий: `comment` у release/collection/article-уведомлений либо
    /// `article_comment` / `collection_comment` у «моих» уведомлений.
    var comment: ReleaseComment?
    var parentComment: ReleaseComment?

    /// Серия (`episode`): имя серии и её релиз.
    var episode: Episode?
    /// Профиль: `profile` либо `by_profile` у уведомлений о друзьях.
    var profile: ProfileBrief?
    /// Статус заявки в друзья: 0 — запрос, 1 — принят (только `type = friend`).
    var status: Int?

    /// Прочитано ли уведомление. В API 11-beta-3 поля `is_read` нет — только
    /// `is_new` (1 — новое), поэтому значение обратное.
    var isRead: Bool? { isNew.map { !$0 } }

    /// Тип уведомления как значение перечисления; `nil` для неизвестного серверу типа.
    var kind: Kind? { type.flatMap(Kind.init(rawValue:)) }

    private enum CodingKeys: String, CodingKey {
        case id, type, timestamp
        case isNew = "is_new"
        case isPushed = "is_pushed"
        case release, comment, episode, profile, status
        case byProfile = "by_profile"
        case articleComment = "article_comment"
        case collectionComment = "collection_comment"
        case parentCommentCamel = "parentComment"
        case parentCommentSnake = "parent_comment"
    }

    private enum CommentExtras: String, CodingKey {
        case release
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        timestamp = try container.decodeIfPresent(Int.self, forKey: .timestamp)
        isNew = try container.decodeIfPresent(Bool.self, forKey: .isNew)
        isPushed = try container.decodeIfPresent(Bool.self, forKey: .isPushed)
        status = try container.decodeIfPresent(Int.self, forKey: .status)

        let episode = try container.decodeIfPresent(Episode.self, forKey: .episode)
        self.episode = episode

        // У разных типов комментарий лежит под разными ключами (см. таблицу выше).
        let commentKey: CodingKeys?
        if let value = try container.decodeIfPresent(ReleaseComment.self, forKey: .comment) {
            comment = value
            commentKey = .comment
        } else if let value = try container.decodeIfPresent(ReleaseComment.self, forKey: .articleComment) {
            comment = value
            commentKey = .articleComment
        } else if let value = try container.decodeIfPresent(ReleaseComment.self, forKey: .collectionComment) {
            comment = value
            commentKey = .collectionComment
        } else {
            comment = nil
            commentKey = nil
        }

        // Релиз лежит на верхнем уровне только у relatedRelease; у episode и
        // releaseComment он вложен — достаём, чтобы `release` работал для всех.
        var resolvedRelease = try container.decodeIfPresent(Release.self, forKey: .release) ?? episode?.release
        if resolvedRelease == nil, let key = commentKey,
           let nested = try? container.nestedContainer(keyedBy: CommentExtras.self, forKey: key) {
            resolvedRelease = try? nested.decodeIfPresent(Release.self, forKey: .release)
        }
        release = resolvedRelease

        // camelCase — так поле называется в APK; snake_case — запасной вариант.
        let parentCamel = try container.decodeIfPresent(ReleaseComment.self, forKey: .parentCommentCamel)
        let parentSnake = try container.decodeIfPresent(ReleaseComment.self, forKey: .parentCommentSnake)
        parentComment = parentCamel ?? parentSnake

        let topProfile = try container.decodeIfPresent(ProfileBrief.self, forKey: .profile)
        let byProfile = try container.decodeIfPresent(ProfileBrief.self, forKey: .byProfile)
        profile = topProfile ?? byProfile
    }
}

extension NotificationItem {
    /// Тип уведомления. `rawValue` совпадает со строкой в поле `type` ответа сервера.
    enum Kind: String, CaseIterable {
        case friend
        case episode
        case releaseComment
        case collectionComment
        case myCollection
        case article
        case articleComment
        case myArticle
        case relatedRelease

        /// Путь удаления этого типа без `/{id}` — из `NotificationApi` в APK.
        var deletePath: String {
            switch self {
            case .friend:
                return "notification/friend/delete"
            case .episode:
                return "notification/episode/delete"
            case .releaseComment:
                return "notification/releaseComment/delete"
            case .collectionComment:
                return "notification/collectionComment/delete"
            case .myCollection:
                return "notification/my/collection/comment/delete"
            case .article:
                return "notification/article/delete"
            case .articleComment:
                return "notification/articleComment/delete"
            case .myArticle:
                return "notification/my/article/comment/delete"
            case .relatedRelease:
                return "notification/related/release/delete"
            }
        }
    }

    /// Сжатый объект `episode` в уведомлении: `EpisodeCompact` из APK.
    struct Episode: Decodable {
        var name: String?
        var release: Release?
    }
}
