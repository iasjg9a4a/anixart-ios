import Foundation

// MARK: - Настройки профиля

/// Настройки текущего аккаунта — ответ `profile/preference/my`.
///
/// Живой сервер отдаёт часть полей сразу в двух видах (`is_private` и `isPrivate`,
/// `is_vk_bound` и `isVkBound`), а часть — только в snake_case, поэтому модель
/// пробует оба ключа для каждого поля. Все поля опциональны: набор зависит от
/// аккаунта (привязки соцсетей, подписка, доступное оформление).
struct AccountPreferences: Decodable {
    /// Код ответа сервера: 0 — успех, остальные значения проверяет `APIClient.check(_:)`.
    let code: Int?

    var avatar: String?
    var status: String?

    var isPrivate: Bool?
    var isIncognito: Bool?
    var isVkBound: Bool?
    var isGoogleBound: Bool?
    var isTelegramBound: Bool?
    var isYandexBound: Bool?

    var privacyStats: Int?
    var privacyCounts: Int?
    var privacySocial: Int?
    var privacyFriendRequests: Int?

    var selectedThemeId: Int?
    var availableThemes: [AccountTheme]?

    /// Подсказка e-mail вида `a**********0@g***l.com`: сам адрес сервер не отдаёт.
    var emailHint: String?

    // Настройки уведомлений — ключи ответа `profile/preference/notification/my`.
    // Метод `notificationPreferences()` переиспользует эту же модель.
    var isReleaseTypeNotificationsEnabled: Bool?
    var isEpisodeNotificationsEnabled: Bool?
    var isFirstEpisodeNotificationEnabled: Bool?
    var isRelatedReleaseNotificationsEnabled: Bool?
    var isReportProcessNotificationsEnabled: Bool?
    var isCommentNotificationsEnabled: Bool?
    var isMyCollectionCommentNotificationsEnabled: Bool?
    var isArticleNotificationsEnabled: Bool?
    var isMyArticleCommentNotificationsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case code, avatar, status
        case isPrivate
        case isPrivateSnake = "is_private"
        case isIncognito
        case isIncognitoSnake = "is_incognito"
        case isVkBound
        case isVkBoundSnake = "is_vk_bound"
        case isGoogleBound
        case isGoogleBoundSnake = "is_google_bound"
        case isTelegramBound
        case isTelegramBoundSnake = "is_telegram_bound"
        case isYandexBound
        case isYandexBoundSnake = "is_yandex_bound"
        case privacyStats
        case privacyStatsSnake = "privacy_stats"
        case privacyCounts
        case privacyCountsSnake = "privacy_counts"
        case privacySocial
        case privacySocialSnake = "privacy_social"
        case privacyFriendRequests
        case privacyFriendRequestsSnake = "privacy_friend_requests"
        case selectedThemeId
        case selectedThemeIdSnake = "selected_theme_id"
        case availableThemes
        case availableThemesSnake = "available_themes"
        case emailHint
        case emailHintSnake = "email_hint"
        case isReleaseTypeNotificationsEnabled
        case isReleaseTypeNotificationsEnabledSnake = "is_release_type_notifications_enabled"
        case isEpisodeNotificationsEnabled
        case isEpisodeNotificationsEnabledSnake = "is_episode_notifications_enabled"
        case isFirstEpisodeNotificationEnabled
        case isFirstEpisodeNotificationEnabledSnake = "is_first_episode_notification_enabled"
        case isRelatedReleaseNotificationsEnabled
        case isRelatedReleaseNotificationsEnabledSnake = "is_related_release_notifications_enabled"
        case isReportProcessNotificationsEnabled
        case isReportProcessNotificationsEnabledSnake = "is_report_process_notifications_enabled"
        case isCommentNotificationsEnabled
        case isCommentNotificationsEnabledSnake = "is_comment_notifications_enabled"
        case isMyCollectionCommentNotificationsEnabled
        case isMyCollectionCommentNotificationsEnabledSnake = "is_my_collection_comment_notifications_enabled"
        case isArticleNotificationsEnabled
        case isArticleNotificationsEnabledSnake = "is_article_notifications_enabled"
        case isMyArticleCommentNotificationsEnabled
        case isMyArticleCommentNotificationsEnabledSnake = "is_my_article_comment_notifications_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        code = try container.decodeIfPresent(Int.self, forKey: .code)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        status = try container.decodeIfPresent(String.self, forKey: .status)

        isPrivate = try AccountPreferences.firstPresent(Bool.self, [.isPrivate, .isPrivateSnake], in: container)
        isIncognito = try AccountPreferences.firstPresent(Bool.self, [.isIncognito, .isIncognitoSnake], in: container)
        isVkBound = try AccountPreferences.firstPresent(Bool.self, [.isVkBound, .isVkBoundSnake], in: container)
        isGoogleBound = try AccountPreferences.firstPresent(Bool.self, [.isGoogleBound, .isGoogleBoundSnake], in: container)
        isTelegramBound = try AccountPreferences.firstPresent(Bool.self, [.isTelegramBound, .isTelegramBoundSnake], in: container)
        isYandexBound = try AccountPreferences.firstPresent(Bool.self, [.isYandexBound, .isYandexBoundSnake], in: container)

        privacyStats = try AccountPreferences.firstPresent(Int.self, [.privacyStats, .privacyStatsSnake], in: container)
        privacyCounts = try AccountPreferences.firstPresent(Int.self, [.privacyCounts, .privacyCountsSnake], in: container)
        privacySocial = try AccountPreferences.firstPresent(Int.self, [.privacySocial, .privacySocialSnake], in: container)
        privacyFriendRequests = try AccountPreferences.firstPresent(Int.self, [.privacyFriendRequests, .privacyFriendRequestsSnake], in: container)

        selectedThemeId = try AccountPreferences.firstPresent(Int.self, [.selectedThemeId, .selectedThemeIdSnake], in: container)
        availableThemes = try AccountPreferences.firstPresent([AccountTheme].self, [.availableThemes, .availableThemesSnake], in: container)
        emailHint = try AccountPreferences.firstPresent(String.self, [.emailHint, .emailHintSnake], in: container)

        isReleaseTypeNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isReleaseTypeNotificationsEnabled, .isReleaseTypeNotificationsEnabledSnake],
            in: container
        )
        isEpisodeNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isEpisodeNotificationsEnabled, .isEpisodeNotificationsEnabledSnake],
            in: container
        )
        isFirstEpisodeNotificationEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isFirstEpisodeNotificationEnabled, .isFirstEpisodeNotificationEnabledSnake],
            in: container
        )
        isRelatedReleaseNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isRelatedReleaseNotificationsEnabled, .isRelatedReleaseNotificationsEnabledSnake],
            in: container
        )
        isReportProcessNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isReportProcessNotificationsEnabled, .isReportProcessNotificationsEnabledSnake],
            in: container
        )
        isCommentNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isCommentNotificationsEnabled, .isCommentNotificationsEnabledSnake],
            in: container
        )
        isMyCollectionCommentNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isMyCollectionCommentNotificationsEnabled, .isMyCollectionCommentNotificationsEnabledSnake],
            in: container
        )
        isArticleNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isArticleNotificationsEnabled, .isArticleNotificationsEnabledSnake],
            in: container
        )
        isMyArticleCommentNotificationsEnabled = try AccountPreferences.firstPresent(
            Bool.self,
            [.isMyArticleCommentNotificationsEnabled, .isMyArticleCommentNotificationsEnabledSnake],
            in: container
        )
    }

    /// Пришли ли в ответе хоть какие-то настройки уведомлений.
    var hasNotificationSettings: Bool {
        [
            isReleaseTypeNotificationsEnabled,
            isEpisodeNotificationsEnabled,
            isFirstEpisodeNotificationEnabled,
            isRelatedReleaseNotificationsEnabled,
            isReportProcessNotificationsEnabled,
            isCommentNotificationsEnabled,
            isMyCollectionCommentNotificationsEnabled,
            isArticleNotificationsEnabled,
            isMyArticleCommentNotificationsEnabled
        ].contains { $0 != nil }
    }

    /// Первое из найденных значений: сервер дублирует ключи в snake_case и camelCase.
    private static func firstPresent<T: Decodable>(_ type: T.Type,
                                                   _ keys: [CodingKeys],
                                                   in container: KeyedDecodingContainer<CodingKeys>) throws -> T? {
        for key in keys {
            if let value = try container.decodeIfPresent(type, forKey: key) {
                return value
            }
        }
        return nil
    }
}

/// Элемент массива `available_themes` из `profile/preference/my`.
/// id 1 — автоматическая тема, 2 — «без темы».
struct AccountTheme: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String?

    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        return "Тема \(id)"
    }
}

// MARK: - APIClient

extension APIClient {
    /// Настройки профиля текущего пользователя (`profile/preference/my`, GET).
    func preferences() async throws -> AccountPreferences {
        let value: AccountPreferences = try await request("profile/preference/my")
        if let code = value.code { try check(code) }
        return value
    }

    /// Сменить статус профиля (`profile/preference/status/edit`).
    ///
    /// Метод определён по APK (`ProfilePreferenceApi.statusEdit` помечен `@POST`, тело —
    /// `StatusEditRequest { status }`, Retrofit с Jackson-конвертером, т.е. JSON) и проверен
    /// живым запросом: GET на этот путь → HTTP 400, POST с JSON `{}` → `{"code":0}`.
    /// Для контраста: GET-эндпоинты (`profile/preference/my`, `.../social`) отвечают и на POST.
    /// Поэтому 400 здесь означает неверный метод, а не тело.
    func updateStatus(_ text: String) async throws {
        let body = try encoder.encode(StatusEditBody(status: text))
        let value: ServerCode = try await request("profile/preference/status/edit",
                                                  method: "POST",
                                                  body: body)
        if let code = value.code { try check(code) }
    }

    /// Настройки уведомлений (`profile/preference/notification/my`, GET).
    /// Возвращает `nil`, если сервер не прислал ни одной настройки.
    func notificationPreferences() async throws -> AccountPreferences? {
        let value: AccountPreferences = try await request("profile/preference/notification/my")
        if let code = value.code { try check(code) }
        return value.hasNotificationSettings ? value : nil
    }

    /// Доступные темы оформления.
    ///
    /// Отдельного read-эндпоинта в API нет: `profile/preference/themes/edit` — это POST-выбор
    /// темы (`ProfilePreferenceApi.selectTheme(SelectThemeRequest { id }, token)`), GET на него
    /// сервер отвергает с HTTP 400. Поэтому список `available_themes` читается из
    /// `profile/preference/my`; выбранная тема при этом не меняется.
    func availableThemes() async throws -> [AccountTheme] {
        let value = try await preferences()
        return value.availableThemes ?? []
    }

    /// Тело `profile/preference/status/edit` — Jackson сериализует поле `status` в JSON.
    private struct StatusEditBody: Encodable {
        let status: String
    }
}
