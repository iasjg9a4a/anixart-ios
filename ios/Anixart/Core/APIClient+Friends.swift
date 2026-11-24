import Foundation

// MARK: - Друзья и заявки
//
// Контракт снят с APK 11-beta-3: интерфейс `network/api/ProfileFriendApi`
// (classes3.dex). Все девять методов помечены Retrofit-аннотацией `@GET` —
// включая «изменяющие» `requestSend`, `requestRemove`, `requestHide`. Это
// распарсенные аннотации dex, а не догадка по сходству путей:
//
//   friends(long id, int page, String token)  GET profile/friend/all/{id}/{page}     → PageableResponse<Profile>
//   recommendations(String token)             GET profile/friend/recommendations     → PageableResponse<Profile>
//   requestsIn(int page, String token)        GET profile/friend/requests/in/{page}   → PageableResponse<Profile>
//   requestsOut(int page, String token)       GET profile/friend/requests/out/{page}  → PageableResponse<Profile>
//   requestSend(long id, String token)        GET profile/friend/request/send/{id}    → SendFriendRequestResponse { code, friend_status }
//   requestRemove(long id, String token)      GET profile/friend/request/remove/{id}  → RemoveFriendRequestResponse { code, friend_status }
//   requestHide(long id, String token)        GET profile/friend/request/hide/{id}    → Response { code }
//
// Живые пробы 24.11.2026 (аккаунт <test-login>, вход form-urlencoded, HTTP 200):
//   • friends — работает; 25 друзей на страницу. Страницы НУМЕРУЮТСЯ С НУЛЯ:
//     на профиле 1601520 (464 друга) `page=0` вернул id [1603988, 1604206, …],
//     `page=1` — [1946854, 1948619, …], пересечений нет; так же ведут себя
//     `filter/{page}`, `release/comment/all/{id}/{page}` и `collection/all/{page}`.
//   • requests/in, requests/out и recommendations — 200 с пустым `content`
//     (у аккаунта 0 друзей и 0 заявок), поэтому формат элемента заявки живым
//     ответом не проверен — см. комментарий к `FriendRequest`.
//   • send/remove/hide живьём НЕ вызывались: это меняющие состояние запросы.

extension APIClient {
    // MARK: - Друзья

    /// Друзья профиля (`profile/friend/all/{id}/{page}`). Читается без входа.
    ///
    /// `page` уходит в путь как есть. Живой бэкенд считает страницы с нуля
    /// (проверено: `page=0` и `page=1` отдают разные 25 записей), поэтому за
    /// первой страницей нужно идти с `page: 0`. По умолчанию здесь `1` — как у
    /// остальных методов `APIClient`; для корректной первой страницы передавайте `0`.
    func friends(profileId: Int, page: Int = 1) async throws -> Paged<ProfileBrief> {
        let value: Paged<ProfileBrief> = try await request("profile/friend/all/\(profileId)/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Входящие заявки в друзья (`profile/friend/requests/in/{page}`). Нужен вход.
    func friendRequestsIn(page: Int = 1) async throws -> Paged<FriendRequest> {
        let value: Paged<FriendRequest> = try await request("profile/friend/requests/in/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Исходящие заявки в друзья (`profile/friend/requests/out/{page}`). Нужен вход.
    func friendRequestsOut(page: Int = 1) async throws -> Paged<FriendRequest> {
        let value: Paged<FriendRequest> = try await request("profile/friend/requests/out/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Рекомендации друзей (`profile/friend/recommendations`). Нужен вход.
    ///
    /// Сервер отдаёт их в конверте страницы (`PageableResponse<Profile>`), хотя
    /// пагинации у метода нет, — возвращаем только `content`. Пустой список —
    /// нормальный ответ (у тестового аккаунта пришёл именно он).
    func recommendations() async throws -> [ProfileBrief]? {
        let value: Paged<ProfileBrief> = try await request("profile/friend/recommendations")
        try check(value.code)
        return value.content
    }

    // MARK: - Заявки: отправка / отмена / скрытие

    /// Отправить заявку в друзья. В APK — `@GET profile/friend/request/send/{id}`.
    func sendRequest(id: Int) async throws {
        try await friendRequestMutation("profile/friend/request/send/\(id)")
    }

    /// Отменить свою заявку. В APK — `@GET profile/friend/request/remove/{id}`.
    func removeRequest(id: Int) async throws {
        try await friendRequestMutation("profile/friend/request/remove/\(id)")
    }

    /// Скрыть входящую заявку. В APK — `@GET profile/friend/request/hide/{id}`.
    func hideRequest(id: Int) async throws {
        try await friendRequestMutation("profile/friend/request/hide/\(id)")
    }

    /// Общий вызов трёх «изменяющих» методов дружбы.
    ///
    /// По dex все они GET (см. шапку файла). Страховка: если прокси ответит
    /// `405 Method Not Allowed`, повторяем POST без тела — состояние к этому
    /// моменту не изменилось, поэтому повтор безопасен. Ответ у всех трёх —
    /// `{"code": …}`, код проверяется через `check`.
    private func friendRequestMutation(_ path: String) async throws {
        do {
            let value: ServerCode = try await request(path)
            if let code = value.code { try check(code, success: [0, 2, 3]) }
        } catch APIError.http(405) {
            let value: ServerCode = try await request(path, method: "POST")
            if let code = value.code { try check(code, success: [0, 2, 3]) }
        }
    }
}

// MARK: - Модели

/// Заявка в друзья — элемент `profile/friend/requests/in|out/{page}`.
///
/// Поля по контракту задачи: `id`, `profile`, `timestamp`. Живым ответом формат
/// не подтверждён: у тестового аккаунта нет заявок, сервер вернул пустой
/// `content`. При этом в APK 11-beta-3 эти же ответы типизированы как
/// `PageableResponse<Profile>` — то есть сервер может отдавать сами профили,
/// без обёртки. Декодер принимает оба варианта: если ключа `profile` в объекте
/// нет, профиль собирается из самого элемента (у профиля тоже есть `id`).
struct FriendRequest: Decodable, Identifiable {
    let id: Int
    var profile: ProfileBrief?
    var timestamp: Int?

    private enum CodingKeys: String, CodingKey {
        case id, profile, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        timestamp = try container.decodeIfPresent(Int.self, forKey: .timestamp)

        if container.contains(.profile) {
            profile = try container.decodeIfPresent(ProfileBrief.self, forKey: .profile)
        } else {
            // Заявка пришла как сам профиль (`PageableResponse<Profile>`).
            profile = try? ProfileBrief(from: decoder)
        }
    }
}
