import Foundation

// MARK: - Избранное видео релиза и коллекций
//
// Пути и HTTP-метод сняты с APK 11-beta-3 (`analysis/endpoints.txt`, интерфейсы
// `network/api/ReleaseVideoFavoriteApi` и `network/api/CollectionFavoriteApi`):
//
//   ReleaseVideoFavoriteApi.add(int r_id, String token)      GET releaseVideoFavorite/add/{r_id}
//   ReleaseVideoFavoriteApi.delete(int r_id, String token)   GET releaseVideoFavorite/delete/{r_id}
//   CollectionFavoriteApi.add(int id, String token)          GET collectionFavorite/add/{id}
//   CollectionFavoriteApi.delete(int id, String token)       GET collectionFavorite/delete/{id}
//
// Это те же «изменяющие» GET-методы, что и в `APIClient+Actions.swift`: токен уходит
// query-параметром `?token=…` (его подставляет `request`), успешные коды ответа —
// 0/2/3 (общий контракт действий с аккаунтом, см. `check(_:success:)`). Все методы
// требуют входа: без токена на живом API они бессмысленны, поэтому сразу отдаём
// `APIError.unauthorized`, не дёргая сеть.
//
// Живьём эти запросы НЕ вызывались: они меняют состояние аккаунта. Пути и метод
// подтверждены разбором dex; коды 0/2/3 взяты из общего контракта действий и на
// живом API не проверялись.

extension APIClient {
    /// Добавить видео релиза в избранное (`releaseVideoFavorite/add/{r_id}`). Нужен вход.
    ///
    /// В dex-шаблоне параметр пути назван `{r_id}`, но ресурс — само видео, поэтому
    /// в путь уходит `videoId`.
    func addReleaseVideoFavorite(videoId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await mediaFavoriteMutation("releaseVideoFavorite/add/\(videoId)")
    }

    /// Убрать видео релиза из избранного (`releaseVideoFavorite/delete/{r_id}`). Нужен вход.
    func removeReleaseVideoFavorite(videoId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await mediaFavoriteMutation("releaseVideoFavorite/delete/\(videoId)")
    }

    /// Добавить коллекцию в избранное (`collectionFavorite/add/{id}`). Нужен вход.
    func addCollectionFavorite(collectionId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await mediaFavoriteMutation("collectionFavorite/add/\(collectionId)")
    }

    /// Убрать коллекцию из избранного (`collectionFavorite/delete/{id}`). Нужен вход.
    func removeCollectionFavorite(collectionId: Int) async throws {
        guard TokenStore.shared.token != nil else { throw APIError.unauthorized }
        try await mediaFavoriteMutation("collectionFavorite/delete/\(collectionId)")
    }

    // MARK: - Общий вызов

    /// Ответ у всех четырёх — базовый `{"code": …}`; успех — 0/2/3.
    ///
    /// Имя отличается от `actionMutation` из `APIClient+Actions.swift` намеренно:
    /// методы приватные для файла, но заглушка CE склеивает исходники в один файл.
    private func mediaFavoriteMutation(_ path: String) async throws {
        let value: ServerCode = try await request(path)
        if let code = value.code { try check(code, success: [0, 2, 3]) }
    }
}
