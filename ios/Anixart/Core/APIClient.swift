import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif

enum APIError: LocalizedError, Equatable {
    case badURL
    case unauthorized
    case http(Int)
    case api(Int)
    case empty
    case authUnavailable
    case invalidCredentials(String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Некорректный адрес запроса"
        case .unauthorized:
            return "Нужен вход в аккаунт Anixart"
        case .http(let code):
            return "Сервер ответил ошибкой HTTP \(code)"
        case .api(let code):
            return "Сервер вернул код \(code)"
        case .empty:
            return "Сервер вернул пустой ответ"
        case .authUnavailable:
            return "Сервер не вернул токен авторизации"
        case .invalidCredentials(let message):
            return message
        case .decoding:
            return "Не удалось разобрать ответ сервера"
        case .transport(let message):
            return "Нет связи с сервером: \(message)"
        }
    }
}

/// Готовые query-параметры фильтра каталога (`GET filter/{page}`).
///
/// Реализация — `ReleaseFilter` из экрана поиска. `APIClient` — слой Core, который CI
/// typecheck'ает отдельно от экранов (джоба `core`, `tools/core_check.sh`), поэтому конкретные
/// типы экранов здесь не упоминаются: клиент принимает любой поставщик параметров, а конформанс
/// объявлен рядом с фильтром — в `Features/Search/SearchView.swift`.
protocol CatalogQueryProviding {
    var queryItems: [URLQueryItem] { get }
}

/// HTTP-клиент к тому же бэкенду, с которым работает Android-приложение.
///
/// Базовый адрес и набор эндпоинтов получен из `classes*.dex` APK `anixart_11-beta-3`
/// и проверен живыми запросами (см. tools/api_probe.py).
final class APIClient {
    static let shared = APIClient()

    /// Адрес бэкенда beta-сборки 11.x.
    let baseURL = URL(string: "https://api-s.anixsekai.com/")!

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json"
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Публичные методы

    func discover() async throws -> Discover {
        let value: Discover = try await request("discover/hub")
        try check(value.code)
        return value
    }

    /// Каталог с сортировкой по умолчанию (свежие обновления).
    func catalog(page: Int = 1) async throws -> Paged<Release> {
        let value: Paged<Release> = try await request("filter/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Каталог с фильтром: тот же `GET filter/{page}`, плюс query-параметры фильтра
    /// (`sort`, `genres`, `year` — см. `ReleaseFilter.queryItems`).
    ///
    /// Страницы у сервера с нуля, в приложении — с единицы, поэтому `page = 1` → `filter/0`.
    func catalog<Filter: CatalogQueryProviding>(page: Int = 1, filter: Filter) async throws -> Paged<Release> {
        let path = "filter/\(max(page - 1, 0))"
        guard let base = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw APIError.badURL
        }
        let items = filter.queryItems
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let url = components.url else { throw APIError.badURL }

        let value: Paged<Release> = try await request(url.absoluteString)
        try check(value.code)
        return value
    }

    /// Поиск релизов. Сервер ждёт POST с JSON-телом.
    func search(_ query: String, page: Int = 1) async throws -> Paged<Release> {
        let body = try encoder.encode(SearchBody(query: query))
        let value: Paged<Release> = try await request("search/releases/\(max(page - 1, 0))", method: "POST", body: body)
        try check(value.code)
        return value
    }

    func release(id: Int) async throws -> Release {
        let value: ReleaseResponse = try await request("release/\(id)")
        try check(value.code)
        return value.release
    }

    func episodeTypes(releaseId: Int) async throws -> [EpisodeType] {
        let value: EpisodeTypesResponse = try await request("episode/\(releaseId)")
        try check(value.code)
        return value.types ?? []
    }

    func episodeSources(releaseId: Int, typeId: Int) async throws -> [EpisodeSource] {
        let value: EpisodeSourcesResponse = try await request("episode/\(releaseId)/\(typeId)")
        try check(value.code)
        return value.sources ?? []
    }

    func episodes(releaseId: Int, typeId: Int, sourceId: Int) async throws -> [Episode] {
        let value: EpisodesResponse = try await request("episode/\(releaseId)/\(typeId)/\(sourceId)")
        try check(value.code)
        return value.episodes ?? []
    }

    /// Возвращает серию вместе с подписанной ссылкой на плеер (Kodik и т.п.).
    /// Ссылка привязана к IP и живёт ограниченное время — запрашивать перед каждым показом.
    func episodeTarget(releaseId: Int, sourceId: Int, position: Int) async throws -> Episode {
        let value: EpisodeTargetResponse = try await request("episode/target/\(releaseId)/\(sourceId)/\(position)")
        try check(value.code)
        guard let episode = value.episode else { throw APIError.empty }
        return episode
    }

    func profile(id: Int) async throws -> Profile {
        let value: ProfileResponse = try await request("profile/\(id)")
        try check(value.code)
        return value.profile
    }

    func profileList(status: ProfileListStatus, page: Int = 1) async throws -> Paged<Release> {
        let value: Paged<Release> = try await request("profile/list/all/\(status.rawValue)/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// История просмотров текущего пользователя (нужен вход).
    func history(page: Int = 1) async throws -> Paged<Release> {
        let value: Paged<Release> = try await request("history/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Избранное текущего пользователя (нужен вход).
    func favorites(page: Int = 1) async throws -> Paged<Release> {
        let value: Paged<Release> = try await request("favorite/all/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Поиск по коллекциям. POST, как и поиск релизов.
    func searchCollections(_ query: String, page: Int = 1) async throws -> Paged<Collection> {
        let body = try encoder.encode(SearchBody(query: query))
        let value: Paged<Collection> = try await request("search/collections/\(max(page - 1, 0))", method: "POST", body: body)
        try check(value.code)
        return value
    }

    /// Поиск по пользователям. POST, как и поиск релизов.
    func searchProfiles(_ query: String, page: Int = 1) async throws -> Paged<ProfileBrief> {
        let body = try encoder.encode(SearchBody(query: query))
        let value: Paged<ProfileBrief> = try await request("search/profiles/\(max(page - 1, 0))", method: "POST", body: body)
        try check(value.code)
        return value
    }

    func collection(id: Int) async throws -> CollectionResponse {
        let value: CollectionResponse = try await request("collection/\(id)")
        try check(value.code)
        return value
    }

    func collectionReleases(id: Int, page: Int = 1) async throws -> Paged<Release> {
        let value: Paged<Release> = try await request("collection/\(id)/releases/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    func notificationCount() async throws -> Int {
        let value: NotificationCountResponse = try await request("notification/count")
        try check(value.code)
        return value.count ?? 0
    }

    /// Отметить серию просмотренной (и записать позицию). Требует входа.
    func markEpisodeWatched(releaseId: Int, sourceId: Int, position: Int) async throws {
        let value: ServerCode = try await request("episode/watch/\(releaseId)/\(sourceId)/\(position)")
        if let code = value.code { try check(code) }
    }

    /// Записать прогресс в историю просмотров. Требует входа.
    func addHistory(releaseId: Int, sourceId: Int, position: Int) async throws {
        let value: ServerCode = try await request("history/add/\(releaseId)/\(sourceId)/\(position)")
        if let code = value.code { try check(code) }
    }

    /// Хаб коллекций: подборки недели, мои и рекомендованные. Доступен без входа.
    func collectionsHub() async throws -> CollectionsHubResponse {
        let value: CollectionsHubResponse = try await request("collection/hub")
        try check(value.code)
        return value
    }

    func collections(page: Int = 1) async throws -> Paged<CollectionBrief> {
        let value: Paged<CollectionBrief> = try await request("collection/all/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Комментарии релиза. Читаются без авторизации.
    func releaseComments(releaseId: Int, page: Int = 1) async throws -> Paged<ReleaseComment> {
        let value: Paged<ReleaseComment> = try await request("release/comment/all/\(releaseId)/\(max(page - 1, 0))")
        try check(value.code)
        return value
    }

    /// Вход по логину и паролю. Возвращает токен.
    ///
    /// Сервер принимает только `application/x-www-form-urlencoded`: на JSON-тело он отвечает
    /// `200` с пустым телом. Проверено на живом API 24.11.2026.
    /// Коды ответа: 0 — успех, 2 — невалидный логин, 3 — неверная пара логин/пароль.
    @discardableResult
    func signIn(login: String, password: String) async throws -> SignInResult {
        let form = "login=\(formEncode(login))&password=\(formEncode(password))"
        guard let body = form.data(using: .utf8) else { throw APIError.badURL }

        let value: AuthResponse = try await request(
            "auth/signIn",
            method: "POST",
            body: body,
            contentType: "application/x-www-form-urlencoded"
        )

        switch value.code {
        case 0:
            if let token = value.profileToken?.token, !token.isEmpty {
                return SignInResult(token: token, profile: value.profile)
            }
            throw APIError.authUnavailable
        case 2:
            throw APIError.invalidCredentials("Логин должен быть от 3 до 20 символов")
        case 3:
            throw APIError.invalidCredentials("Неверный логин или пароль")
        default:
            throw APIError.api(value.code)
        }
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Транспорт

    private struct SearchBody: Encodable {
        let query: String
    }

    /// Некоторые эндпоинты (например, заявки в друзья) возвращают 2/3 как «успех»
    /// — сервер так кодирует результат операции. `success` задаёт допустимые коды.
    func check(_ code: Int, success: Set<Int> = [0]) throws {
        if success.contains(code) { return }
        if code == 401 { throw APIError.unauthorized }
        throw APIError.api(code)
    }

    /// Один обмен с сервером: `session.data(for:)` и проверка HTTP-статуса.
    ///
    /// Статус проверяется здесь, а не в наружном методе, чтобы повторитель видел
    /// `.http(5xx)`/`.http(429)` — только такие ответы `Retry.isRetryable` и повторяет.
    /// Таймаут один: он приходит из конфигурации `URLSession` (25 с на запрос), у каждой
    /// попытки свой запрос, отдельных таймеров поверх не появляется.
    private func perform(_ urlRequest: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("пустой HTTP-ответ")
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return data
    }

    func request<T: Decodable>(_ path: String,
                                       method: String = "GET",
                                       body: Data? = nil,
                                       contentType: String = "application/json") async throws -> T {
        guard let base = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw APIError.badURL
        }

        // Оригинальное приложение передаёт сессию query-параметром `token`
        // (проверено: заголовки token/Authorization сервер игнорирует).
        if let token = TokenStore.shared.token {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
        }

        guard let url = components.url else { throw APIError.badURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Anixart-iOS/1.0 (iPhone; iOS)", forHTTPHeaderField: "User-Agent")

        if let body = body {
            urlRequest.httpBody = body
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        // Повторяем только чтение: POST/PUT/DELETE меняют состояние на сервере,
        // и повтор после таймаута рискует задвоить операцию (вход, закладка и т.п.).
        let data: Data
        if method.uppercased() == "GET" {
            data = try await Retry.run(RetryPolicy.default, isRetryable: Retry.isRetryable) {
                try await self.perform(urlRequest)
            }
        } else {
            data = try await perform(urlRequest)
        }

        guard !data.isEmpty else { throw APIError.empty }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if let status = try? decoder.decode(ServerCode.self, from: data),
               let code = status.code, code != 0 {
                throw (code == 401 ? APIError.unauthorized : APIError.api(code))
            }
            throw APIError.decoding(String(describing: error))
        }
    }
}
