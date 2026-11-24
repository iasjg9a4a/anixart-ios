import Foundation

// MARK: - Действия со списками профиля, избранным и голосом за релиз
//
// Контракт снят с APK 11-beta-3: `classes3.dex`, интерфейсы
// `network/api/ProfileListApi`, `network/api/FavoriteApi`, `network/api/ReleaseApi`.
// Все шесть методов помечены Retrofit-аннотацией `@GET`; это распарсенные
// аннотации dex, а не догадка по сходству путей (метод GET подтверждён
// аннотациями в dex):
//
//   ProfileListApi.add(int status, long r_id, …)      GET profile/list/add/{status}/{r_id}
//   ProfileListApi.delete(int status, long r_id, …)   GET profile/list/delete/{status}/{r_id}
//   FavoriteApi.add(long r_id, String token)          GET favorite/add/{r_id}
//   FavoriteApi.delete(long r_id, String token)       GET favorite/delete/{r_id}
//   ReleaseApi.vote(long r_id, int vote, String token) GET release/vote/add/{r_id}/{vote}
//   ReleaseApi.deleteVote(long r_id, String token)    GET release/vote/delete/{r_id}
//
// Последний параметр каждого метода в APK — `String token`: токен уходит
// query-параметром `?token=…`, это делает `request` в APIClient.swift.
// Успешный ответ — базовый `Response { code }`, поэтому коды проверяются через
// `check`: 0/2/3 считаются успехом (так сервер кодирует исход операции — тот же
// контракт, что у заявок в друзья, см. комментарий к `check(_:success:)`).
//
// Живьём эти запросы НЕ вызывались: они меняют состояние аккаунта (список,
// избранное, голос). По dex подтверждены путь и HTTP-метод; коды ответа взяты
// из общего контракта «изменяющих» операций, на живом API не проверялись.

extension APIClient {
    // MARK: - Списки профиля

    /// Добавить релиз в список профиля (`profile/list/add/{status}/{r_id}`). Нужен вход.
    ///
    /// `status` уходит числом `ProfileListStatus.rawValue` (1 — смотрю, 2 — в планах,
    /// 3 — просмотрено, 4 — отложено, 5 — брошено).
    func addToList(releaseId: Int, status: ProfileListStatus) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await actionMutation("profile/list/add/\(status.rawValue)/\(releaseId)")
    }

    /// Убрать релиз из списка профиля (`profile/list/delete/{status}/{r_id}`). Нужен вход.
    func removeFromList(releaseId: Int, status: ProfileListStatus) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await actionMutation("profile/list/delete/\(status.rawValue)/\(releaseId)")
    }

    // MARK: - Избранное

    /// Добавить релиз в избранное (`favorite/add/{r_id}`). Нужен вход.
    func addToFavorites(releaseId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await actionMutation("favorite/add/\(releaseId)")
    }

    /// Убрать релиз из избранного (`favorite/delete/{r_id}`). Нужен вход.
    func removeFromFavorites(releaseId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await actionMutation("favorite/delete/\(releaseId)")
    }

    // MARK: - Голос за релиз

    /// Поставить оценку релизу (`release/vote/add/{r_id}/{vote}`). Нужен вход.
    ///
    /// `vote` — число голоса; допустимый диапазон проверяет сервер, ответ — `{"code": …}`.
    func vote(releaseId: Int, vote: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await actionMutation("release/vote/add/\(releaseId)/\(vote)")
    }

    /// Отозвать свою оценку (`release/vote/delete/{r_id}`). Нужен вход.
    func deleteVote(releaseId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await actionMutation("release/vote/delete/\(releaseId)")
    }

    // MARK: - Общий вызов

    /// Вызов «изменяющего» GET-метода: ответ у всех шести — `{"code": …}`.
    ///
    /// Параметр `token` подставляет `request`, когда пользователь вошёл; код ответа
    /// проверяется как успешный при 0/2/3.
    private func actionMutation(_ path: String) async throws {
        let value: ServerCode = try await request(path)
        if let code = value.code { try check(code, success: [0, 2, 3]) }
    }
}
