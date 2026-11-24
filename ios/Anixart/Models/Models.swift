import Foundation

// MARK: - Справочники

struct NamedRef: Codable, Hashable {
    let id: Int
    var name: String?
}

// MARK: - Релиз

/// Модель релиза. Сервер отдаёт один и тот же объект в каталоге, поиске и на странице релиза,
/// поэтому почти все поля опциональны: в списках часть из них отсутствует.
struct Release: Codable, Identifiable {
    let id: Int

    var titleRu: String?
    var titleOriginal: String?
    var titleAlt: String?
    var image: String?
    var year: String?
    var genres: String?
    var country: String?
    var studio: String?
    var director: String?
    var author: String?
    var translators: String?
    var source: String?
    var summary: String?
    var note: String?
    var releaseDate: String?

    var category: NamedRef?
    var status: NamedRef?

    var rating: Int?
    var grade: Double?
    var duration: Int?
    /// Сезон релиза (`season`), 0 — не указан.
    var season: Int?
    /// Возрастной рейтинг (`age_rating`), 0 — не указан.
    var ageRating: Int?
    var episodesReleased: Int?
    var episodesTotal: Int?

    var isAdult: Bool?
    var isPlayDisabled: Bool?
    var isDeleted: Bool?
    /// Смотрел ли релиз текущий пользователь. У анонима всегда `false`.
    var isViewed: Bool?
    /// Лежит ли релиз в избранном текущего пользователя.
    var isFavorite: Bool?
    /// Голос текущего пользователя: 1–5, `0` — не голосовал, у анонима `null`.
    var yourVote: Int?

    var commentCount: Int?
    var favoritesCount: Int?
    var voteCount: Int?
    /// Сколько коллекций включают релиз (`collection_count`).
    var collectionCount: Int?

    var relatedReleases: [Release]?
    /// Франшиза релиза (`related`). Её `id` — аргумент для `related/{relatedId}/{page}`.
    var related: RelatedFranchise?
    var recommendedReleases: [Release]?
    var screenshotImages: [String]?
    var comments: [ReleaseComment]?
    var lastViewEpisode: LastViewEpisode?

    var profileListStatus: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case titleRu = "title_ru"
        case titleOriginal = "title_original"
        case titleAlt = "title_alt"
        case image, year, genres, country, studio, director, author, translators, source, note
        case summary = "description"
        case releaseDate = "release_date"
        case category, status, rating, grade, duration
        case season
        case ageRating = "age_rating"
        case episodesReleased = "episodes_released"
        case episodesTotal = "episodes_total"
        case isAdult = "is_adult"
        case isPlayDisabled = "is_play_disabled"
        case isDeleted = "is_deleted"
        case isViewed = "is_viewed"
        case isFavorite = "is_favorite"
        case yourVote = "your_vote"
        case commentCount = "comment_count"
        case favoritesCount = "favorites_count"
        case voteCount = "vote_count"
        case collectionCount = "collection_count"
        case relatedReleases = "related_releases"
        case related
        case recommendedReleases = "recommended_releases"
        case screenshotImages = "screenshot_images"
        case comments
        case lastViewEpisode = "last_view_episode"
        case profileListStatus = "profile_list_status"
    }

    var displayTitle: String {
        if let title = titleRu, !title.isEmpty { return title }
        if let title = titleOriginal, !title.isEmpty { return title }
        return "Без названия"
    }

    var subtitle: String {
        [year, category?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var posterURL: URL? {
        guard let raw = image, !raw.isEmpty else { return nil }
        let url = URL(string: raw)
        return url?.scheme == nil ? nil : url
    }

    var genreList: [String] {
        (genres ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var episodesText: String {
        let total = episodesTotal ?? 0
        let released = episodesReleased ?? 0
        if total == 0 {
            return released > 0 ? "\(released) серий" : "Серии неизвестны"
        }
        return released < total ? "\(released) из \(total) серий" : "\(total) серий"
    }

    var gradeText: String {
        guard let grade = grade, grade > 0 else { return "—" }
        return String(format: "%.2f", grade)
    }
}

/// Франшиза («родственное»), к которой относится релиз, — поле `release.related`.
///
/// Приходит живым ответом `release/{id}`: `{id, name, name_ru, description, image,
/// images, release_count}`; `image` бывает пустой строкой, `description` — `null`.
/// Отдельно от `related_releases`: это группа релизов, а не список соседей.
struct RelatedFranchise: Codable, Identifiable {
    let id: Int
    var name: String?
    var nameRu: String?
    var description: String?
    var image: String?
    var images: [String]?
    var releaseCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description, image, images
        case nameRu = "name_ru"
        case releaseCount = "release_count"
    }

    /// Название франшизы: русское, если сервер его дал, иначе системное.
    var displayTitle: String {
        if let nameRu = nameRu, !nameRu.isEmpty { return nameRu }
        if let name = name, !name.isEmpty { return name }
        return "Франшиза"
    }
}

// MARK: - Коллекция

struct CollectionBrief: Codable, Identifiable {
    let id: Int
    var title: String?
    var image: String?
    var releaseCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, image
        case releaseCount = "release_count"
    }

    var displayTitle: String { title?.isEmpty == false ? title! : "Коллекция" }
}

/// Элемент `profile.collections_preview`.
///
/// Сервер смешивает в этом массиве полные объекты и голые id: живой ответ
/// `profile/1601520` — `[{…}, 159946, 178933]`, `profile/1946854` — `[{…}, 178935]`.
/// Поэтому элемент читает оба вида: у id-формы заполнен только `id`,
/// у объектной — те же поля, что у `CollectionBrief`.
struct CollectionPreview: Codable, Identifiable {
    let id: Int
    var title: String?
    var image: String?
    var releaseCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, image
        case releaseCount = "release_count"
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let id = try? single.decode(Int.self) {
            self.id = id
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        releaseCount = try container.decodeIfPresent(Int.self, forKey: .releaseCount)
    }

    var displayTitle: String { title?.isEmpty == false ? title! : "Коллекция" }
}

// MARK: - Профиль

struct Profile: Codable, Identifiable {
    let id: Int
    var login: String?
    var avatar: String?
    var status: String?
    var registerDate: Int?
    var isVerified: Bool?
    var isSponsor: Bool?
    /// Был ли пользователь в сети на момент ответа (`is_online`). Есть у любого профиля.
    var isOnline: Bool?
    /// Оценка профиля 0–10 (`rating_score`); у анонимных и новых аккаунтов бывает 0.
    var ratingScore: Int?

    var watchingCount: Int?
    var planCount: Int?
    var completedCount: Int?
    var holdOnCount: Int?
    var droppedCount: Int?
    var favoriteCount: Int?
    var watchedEpisodeCount: Int?
    var commentCount: Int?
    var collectionCount: Int?

    /// Мини-карточки друзей (`friends_preview`, до 3 штук).
    /// Поля элемента совпадают с `ProfileBrief` (поиск/друзья), поэтому модель общая.
    var friendsPreview: [ProfileBrief]?
    /// Превью коллекций профиля (`collections_preview`, до 3 штук).
    /// Сервер смешивает полные объекты и голые id — см. `CollectionPreview`.
    var collectionsPreview: [CollectionPreview]?
    /// Витрина значков (`badges_preview`): до 8 значков, что показываются в профиле.
    var badgesPreview: [BadgePreview]?
    /// Динамика просмотров по дням (`watch_dynamics`, обычно 31 запись).
    var watchDynamics: [WatchDynamics]?

    enum CodingKeys: String, CodingKey {
        case id, login, avatar, status
        case registerDate = "register_date"
        case isVerified = "is_verified"
        case isSponsor = "is_sponsor"
        case isOnline = "is_online"
        case ratingScore = "rating_score"
        case watchingCount = "watching_count"
        case planCount = "plan_count"
        case completedCount = "completed_count"
        case holdOnCount = "hold_on_count"
        case droppedCount = "dropped_count"
        case favoriteCount = "favorite_count"
        case watchedEpisodeCount = "watched_episode_count"
        case commentCount = "comment_count"
        case collectionCount = "collection_count"
        case friendsPreview = "friends_preview"
        case collectionsPreview = "collections_preview"
        case badgesPreview = "badges_preview"
        case watchDynamics = "watch_dynamics"
    }

    var displayName: String { login?.isEmpty == false ? login! : "Профиль" }

    var avatarURL: URL? {
        guard let raw = avatar, !raw.isEmpty else { return nil }
        let url = URL(string: raw)
        return url?.scheme == nil ? nil : url
    }
}

// MARK: - Значки и динамика профиля

/// Значок профиля — элемент `profile.badges_preview` (и витрины значков).
///
/// Живой ответ `profile/{id}`: `id`, `type`, `name`, `description`, `timestamp`,
/// `category {id, title}`, `award` (у «наградных» значков), `rarity`
/// (`COMMON`/`UNCOMMON`/`RARE`/`EPIC`/`LEGENDARY`), `image_url` и производные
/// `image_small_url`/`image_medium_url`/`image_preview_url`, `ownership_percentage`,
/// `is_showcased`/`is_owned`/`is_available`/`is_selected`. Всё, кроме `id`, опционально.
struct BadgePreview: Codable, Identifiable {
    let id: Int
    var type: Int?
    var name: String?
    var description: String?
    /// Unix-время получения значка; у витрины часто 0.
    var timestamp: Int?
    var rarity: String?
    var imageURL: String?
    var imageSmallURL: String?
    var imageMediumURL: String?
    var imagePreviewURL: String?
    /// Доля пользователей с этим значком в процентах (0–100).
    var ownershipPercentage: Double?
    var isShowcased: Bool?
    var isOwned: Bool?
    var isAvailable: Bool?
    var isSelected: Bool?
    var category: BadgeCategory?
    var award: BadgeAward?

    enum CodingKeys: String, CodingKey {
        case id, type, name, description, timestamp, rarity, category, award
        case imageURL = "image_url"
        case imageSmallURL = "image_small_url"
        case imageMediumURL = "image_medium_url"
        case imagePreviewURL = "image_preview_url"
        case ownershipPercentage = "ownership_percentage"
        case isShowcased = "is_showcased"
        case isOwned = "is_owned"
        case isAvailable = "is_available"
        case isSelected = "is_selected"
    }

    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        return "Значок"
    }

    /// Наименьшая доступная картинка: маленькая, иначе обычная.
    var image: String? { imageSmallURL ?? imageURL ?? imageMediumURL }
}

/// Категория значка (`badges_preview[].category`), например «Просмотр аниме».
struct BadgeCategory: Codable, Identifiable {
    let id: Int
    var title: String?
}

/// Награда, за которую выдан значок (`badges_preview[].award`).
/// Для событийных значков сервер присылает `null`.
struct BadgeAward: Codable {
    /// Причина выдачи, например `EPISODE_WATCHED`.
    var trigger: String?
    var releaseId: Int?
    var releaseTitle: String?
    var releaseImage: String?
    var episodeName: String?
    var profileListStatus: Int?

    enum CodingKeys: String, CodingKey {
        case trigger
        case releaseId = "release_id"
        case releaseTitle = "release_title"
        case releaseImage = "release_image"
        case episodeName = "episode_name"
        case profileListStatus = "profile_list_status"
    }
}

/// Точка динамики просмотров — элемент `profile.watch_dynamics`.
/// Живой ответ: `{id, day, count, timestamp}`; `day` — номер дня месяца.
struct WatchDynamics: Codable, Identifiable {
    let id: Int
    var day: Int?
    var count: Int?
    var timestamp: Int?
}

/// Статусы списков профиля. Значения совпадают с тем, что ожидает `profile/list/all/{status}/{page}`.
enum ProfileListStatus: Int, CaseIterable, Identifiable {
    case watching = 1
    case planned = 2
    case completed = 3
    case holdOn = 4
    case dropped = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .watching: return "Смотрю"
        case .planned: return "В планах"
        case .completed: return "Просмотрено"
        case .holdOn: return "Отложено"
        case .dropped: return "Брошено"
        }
    }
}

// MARK: - Озвучки, источники, серии

struct EpisodeType: Codable, Identifiable {
    let id: Int
    var name: String?
    var icon: String?
    var workers: String?
    var isSub: Bool?
    var episodesCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, workers
        case isSub = "is_sub"
        case episodesCount = "episodes_count"
    }

    var displayName: String { name?.isEmpty == false ? name! : "Озвучка" }
}

struct EpisodeSource: Codable, Identifiable {
    let id: Int
    var name: String?
    var type: EpisodeType?
    var episodesCount: Int?
    var quality: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, quality
        case episodesCount = "episodes_count"
    }

    var displayName: String { name?.isEmpty == false ? name! : "Источник" }
}

struct Episode: Codable, Identifiable {
    var position: Int
    var releaseId: Int?
    var sourceId: Int?
    var name: String?
    var url: String?
    var iframe: Bool?
    var quality: Int?
    var addedDate: Int?
    var isWatched: Bool?
    var isFiller: Bool?

    /// Серии приходят из разных источников, поэтому позиция сама по себе не уникальна.
    var id: String { "\(sourceId ?? 0)-\(position)" }

    enum CodingKeys: String, CodingKey {
        case position, name, url, iframe, quality
        case releaseId, sourceId
        case addedDate = "addedDate"
        case isWatched = "is_watched"
        case isFiller = "is_filler"
    }

    var displayName: String { name?.isEmpty == false ? name! : "Серия \(position)" }
}

// MARK: - Комментарии

struct CommentAuthor: Codable, Identifiable {
    let id: Int
    var login: String?
    var avatar: String?
    var isVerified: Bool?

    enum CodingKeys: String, CodingKey {
        case id, login, avatar
        case isVerified = "is_verified"
    }

    var displayName: String { login?.isEmpty == false ? login! : "Пользователь" }
}

struct ReleaseComment: Codable, Identifiable {
    let id: Int
    var message: String?
    var timestamp: Int?
    var profile: CommentAuthor?
    var vote: Int?
    var voteCount: Int?
    var likesCount: Int?
    var replyCount: Int?
    var isSpoiler: Bool?
    var isEdited: Bool?
    var isDeleted: Bool?
    var isReply: Bool?
    var canLike: Bool?

    enum CodingKeys: String, CodingKey {
        case id, message, timestamp, profile, vote
        case voteCount = "vote_count"
        case likesCount = "likes_count"
        case replyCount = "reply_count"
        case isSpoiler = "is_spoiler"
        case isEdited = "is_edited"
        case isDeleted = "is_deleted"
        case isReply = "is_reply"
        case canLike = "can_like"
    }

    var isVisible: Bool { isDeleted != true }
}

// MARK: - Ответы сервера

struct ServerCode: Decodable {
    let code: Int?
    let message: String?
}

struct Paged<Item: Decodable>: Decodable {
    let code: Int
    let content: [Item]
    let totalCount: Int?
    let totalPageCount: Int?
    let currentPage: Int?

    enum CodingKeys: String, CodingKey {
        case code, content
        case totalCount = "total_count"
        case totalPageCount = "total_page_count"
        case currentPage = "current_page"
    }

    /// Сервер иногда отвечает `{"code": 0}` без списка — это не ошибка декодирования.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        content = try container.decodeIfPresent([Item].self, forKey: .content) ?? []
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
        totalPageCount = try container.decodeIfPresent(Int.self, forKey: .totalPageCount)
        // Сервер нумерует страницы с нуля, в приложении — с единицы.
        if let serverPage = try container.decodeIfPresent(Int.self, forKey: .currentPage) {
            currentPage = serverPage + 1
        } else {
            currentPage = nil
        }
    }
}

/// Ответ `discover/hub` — все блоки главного экрана за один запрос.
///
/// Живой ответ 24.11.2026 (с токеном и без): `watching` 25, `discussing` 5,
/// `collections` 25, `comments` 10, `interesting` 17, `recommendations` может быть
/// пустым для аккаунта без персональных рекомендаций. `collections_page` —
/// следующая страница коллекций, `collections_page_count` — их всего.
struct Discover: Decodable {
    let code: Int
    let watching: [Release]?
    let discussing: [Release]?
    let collections: [CollectionBrief]?
    let interesting: [InterestingItem]?
    /// Персональные рекомендации (`recommendations`); форма элемента — как у релиза.
    let recommendations: [Release]?
    /// «Комментарии недели» (`comments`, 10 штук) — та же форма, что у комментариев релиза.
    let comments: [ReleaseComment]?
    /// Номер страницы рекомендаций (`recommendations_page`, с нуля).
    let recommendationsPage: Int?
    /// Номер страницы блока коллекций (`collections_page`, с нуля).
    let collectionsPage: Int?
    /// Всего страниц коллекций (`collections_page_count`).
    let collectionsPageCount: Int?

    enum CodingKeys: String, CodingKey {
        case code, watching, discussing, collections, interesting, recommendations, comments
        case recommendationsPage = "recommendations_page"
        case collectionsPage = "collections_page"
        case collectionsPageCount = "collections_page_count"
    }
}

/// Баннер на главной (`discover/hub` → `interesting`).
struct InterestingItem: Codable, Identifiable {
    let id: Int
    var title: String?
    var description: String?
    var image: String?
    var imageAnimation: String?
    var type: Int?
    var action: String?
    var isHidden: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, description, image, type, action
        case imageAnimation = "image_animation"
        case isHidden = "is_hidden"
    }
}

/// Последняя просмотренная серия — приходит в истории и в релизе.
struct LastViewEpisode: Codable {
    var releaseId: Int?
    var sourceId: Int?
    var position: Int?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case position, name, releaseId, sourceId
    }
}

struct CollectionsHubResponse: Decodable {
    let code: Int
    let weekly: [CollectionBrief]?
    let my: [CollectionBrief]?
    let recommended: [CollectionBrief]?
    /// Сколько коллекций у текущего пользователя (`my_count`); без входа — 0.
    let myCount: Int?

    enum CodingKeys: String, CodingKey {
        case code, weekly, my, recommended
        case myCount = "my_count"
    }
}

struct ReleaseResponse: Decodable {
    let code: Int
    let release: Release
}

struct ProfileResponse: Decodable {
    let code: Int
    let profile: Profile
    let isMyProfile: Bool?

    enum CodingKeys: String, CodingKey {
        case code, profile
        case isMyProfile = "is_my_profile"
    }
}

struct EpisodeTypesResponse: Decodable {
    let code: Int
    let types: [EpisodeType]?
}

struct EpisodeSourcesResponse: Decodable {
    let code: Int
    let sources: [EpisodeSource]?
}

struct EpisodesResponse: Decodable {
    let code: Int
    let episodes: [Episode]?
}

struct EpisodeTargetResponse: Decodable {
    let code: Int
    let episode: Episode?
}

/// Сессия, которую сервер выдаёт при входе. `token` подставляется в каждый запрос
/// query-параметром `?token=…` — так же делает оригинальное приложение.
struct ProfileToken: Decodable {
    let id: Int
    let token: String
}

struct AuthResponse: Decodable {
    let code: Int
    let profile: Profile?
    let profileToken: ProfileToken?
}

struct SignInResult {
    let token: String
    let profile: Profile?
}

// MARK: - Краткие карточки (поиск, друзья)

struct ProfileBrief: Codable, Identifiable {
    let id: Int
    var login: String?
    var avatar: String?
    var isOnline: Bool?
    var isVerified: Bool?
    var isSponsor: Bool?
    var badgeName: String?
    var badgeURL: String?

    enum CodingKeys: String, CodingKey {
        case id, login, avatar
        case isOnline = "is_online"
        case isVerified = "is_verified"
        case isSponsor = "is_sponsor"
        case badgeName = "badge_name"
        case badgeURL = "badge_url"
    }

    var displayName: String { login?.isEmpty == false ? login! : "Пользователь" }
}

struct Collection: Codable, Identifiable {
    let id: Int
    var title: String?
    var description: String?
    var image: String?
    var releaseCount: Int?
    /// Автор коллекции (`creator`) — живой ответ `collection/{id}` и `collection/hub`
    /// присылает полный профиль; здесь достаточно мини-карточки.
    var creator: ProfileBrief?
    /// - Warning: устарело и всегда `nil`: сервер НЕ отдаёт `creator_id`
    ///   (ни в `collection/{id}`, ни в `collection/hub`). Автор приходит объектом
    ///   `creator` — id берите из `creator?.id`. Поле сохранено ради совместимости.
    var creatorId: Int?
    var favoritesCount: Int?
    var commentCount: Int?
    var isPrivate: Bool?
    var isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, description, image
        case releaseCount = "release_count"
        case creator
        case creatorId = "creator_id"
        case favoritesCount = "favorites_count"
        case commentCount = "comment_count"
        case isPrivate = "is_private"
        case isFavorite = "is_favorite"
    }

    var displayTitle: String { title?.isEmpty == false ? title! : "Коллекция" }
}

/// Ответ `collection/{id}`: коллекция и счётчики релизов в ней по статусам списков.
///
/// Живой ответ 24.11.2026: все пять счётчиков присутствуют
/// (`watching_count`, `plan_count`, `completed_count`, `hold_on_count`, `dropped_count`).
struct CollectionResponse: Decodable {
    let code: Int
    let collection: Collection
    let watchingCount: Int?
    let planCount: Int?
    let completedCount: Int?
    let holdOnCount: Int?
    let droppedCount: Int?

    enum CodingKeys: String, CodingKey {
        case code, collection
        case watchingCount = "watching_count"
        case planCount = "plan_count"
        case completedCount = "completed_count"
        case holdOnCount = "hold_on_count"
        case droppedCount = "dropped_count"
    }
}

struct NotificationCountResponse: Decodable {
    let code: Int
    let count: Int?
}
