import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif
@testable import Anixart

// TODO(APIClient): сетевой слой пока не тестируется целиком.
// `APIClient` создаёт свою `URLSession` в `private init`:
//     let configuration = URLSessionConfiguration.default
//     session = URLSession(configuration: configuration)
// Конфигурация наружу не отдаётся, поэтому `MockURLProtocol` нельзя подставить
// в клиентский URLSession — перехватить реальный запрос (и проверить, что в URL
// есть queryItem token) можно только после доработки APIClient: internal
// `init(configuration: URLSessionConfiguration)` (или `init(session: URLSession)`).
// После этого здесь появятся тесты на:
//   • release(id:) — запрос уходит с queryItem token;
//   • profile(id:) при HTTP 200 и теле {"code":401} — APIError.unauthorized;
//   • markEpisodeWatched(...) — HTTP 200 + {"code":5} — APIError.api(5).
// Сейчас проверяются только те части контракта, которые не требуют подмены сети:
// маппинг кодов (`check`) и разбор ответов тем же `JSONDecoder`, что у APIClient.

// MARK: - Подмена сети

/// URLProtocol-заглушка: отдаёт заранее заданный ответ вместо реального запроса.
///
/// Готова для тестов `APIClient` после инъекции сессии (см. TODO выше).
/// Пока используется только для проверки самого стенда
/// (`testMockURLProtocolInterceptsRequest`).
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Тесты

final class APIClientTests: XCTestCase {
    /// Общий клиент приложения — тестируем именно его.
    private var client: APIClient { APIClient.shared }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        TokenStore.shared.clear()
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        TokenStore.shared.clear()
        super.tearDown()
    }

    // MARK: Коды ответов сервера (APIClient.check)

    func testCheckZeroDoesNotThrow() {
        XCTAssertNoThrow(try client.check(0))
    }

    func testCheck401ThrowsUnauthorized() {
        XCTAssertThrowsError(try client.check(401)) { error in
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
    }

    func testCheckNonZeroCodesThrowAPIError() {
        for code in [2, 3, 5, 500] {
            XCTAssertThrowsError(try client.check(code), "код \(code) должен быть ошибкой") { error in
                XCTAssertEqual(error as? APIError, .api(code), "ожидали APIError.api(\(code))")
            }
        }
    }

    /// Тело ответа `episode/watch/...`: `{"code":0}` — успех, `{"code":5}` — ошибка API.
    /// Повторяет обработку из `APIClient.markEpisodeWatched` (декод `ServerCode` + `check`).
    /// Сам сетевой вызов пока не проверить: см. TODO в начале файла.
    func testWatchResponseCodes() throws {
        let ok = try client.decoder.decode(ServerCode.self, from: Data(#"{"code":0}"#.utf8))
        let okCode = try XCTUnwrap(ok.code)
        XCTAssertEqual(okCode, 0)
        XCTAssertNoThrow(try client.check(okCode))

        let failure = try client.decoder.decode(ServerCode.self, from: Data(#"{"code":5}"#.utf8))
        let failureCode = try XCTUnwrap(failure.code)
        XCTAssertThrowsError(try client.check(failureCode)) { error in
            XCTAssertEqual(error as? APIError, .api(5))
        }
    }

    // MARK: Разбор ответов

    func testReleaseResponseDecodes() throws {
        let body = #"{"code":0,"release":{"id":1,"title_ru":"Тест"}}"#
        let response = try client.decoder.decode(ReleaseResponse.self, from: Data(body.utf8))
        XCTAssertEqual(response.code, 0)
        XCTAssertEqual(response.release.id, 1)
        XCTAssertEqual(response.release.titleRu, "Тест")
        XCTAssertEqual(response.release.displayTitle, "Тест")
    }

    func testProfileResponseDecodes() throws {
        let body = #"{"code":0,"profile":{"id":7,"login":"viewer"}}"#
        let response = try client.decoder.decode(ProfileResponse.self, from: Data(body.utf8))
        XCTAssertEqual(response.code, 0)
        XCTAssertEqual(response.profile.id, 7)
        XCTAssertEqual(response.profile.login, "viewer")
        XCTAssertEqual(response.profile.displayName, "viewer")
    }

    /// Ключевая ветка ошибки: сервер отдаёт HTTP 200 с телом `{"code":401}`.
    /// `ProfileResponse` из такого тела не разбирается, поэтому `APIClient.request`
    /// падает в запасной декод `ServerCode` и превращает код 401 в `.unauthorized`.
    func testErrorBody401MapsToUnauthorized() throws {
        let body = Data(#"{"code":401}"#.utf8)

        // 1. Основной декод падает — как в APIClient.request.
        XCTAssertThrowsError(try client.decoder.decode(ProfileResponse.self, from: body))

        // 2. Запасной декод ServerCode даёт код 401.
        let status = try client.decoder.decode(ServerCode.self, from: body)
        let code = try XCTUnwrap(status.code)

        // 3. check превращает его в APIError.unauthorized.
        XCTAssertThrowsError(try client.check(code)) { error in
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
    }

    /// Сервер иногда отвечает `{"code":0}` без списка — это не ошибка (см. Paged.init(from:)).
    func testPagedWithoutContentDecodesEmpty() throws {
        let page = try client.decoder.decode(Paged<Release>.self, from: Data(#"{"code":0}"#.utf8))
        XCTAssertEqual(page.code, 0)
        XCTAssertTrue(page.content.isEmpty)
        XCTAssertNil(page.totalCount)
    }

    /// `episode/target/...` без `episode` — APIClient превращает это в `APIError.empty`.
    func testEpisodeTargetWithoutEpisodeDecodesNil() throws {
        let response = try client.decoder.decode(EpisodeTargetResponse.self, from: Data(#"{"code":0}"#.utf8))
        XCTAssertEqual(response.code, 0)
        XCTAssertNil(response.episode)
    }

    func testAPIErrorDescriptionsAreNotEmpty() {
        let errors: [APIError] = [
            .badURL,
            .unauthorized,
            .http(500),
            .api(5),
            .empty,
            .authUnavailable,
            .invalidCredentials("Неверный логин или пароль"),
            .decoding("test"),
            .transport("test")
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "пустое описание у \(error)")
        }
        XCTAssertEqual(APIError.api(5).errorDescription, "Сервер вернул код 5")
        XCTAssertEqual(APIError.http(500).errorDescription, "Сервер ответил ошибкой HTTP 500")
    }

    // MARK: Транспорт (без подмены сети)

    /// `APIClient.request` оборачивает ошибку URLSession в `APIError.transport`.
    /// Соединение с закрытым портом localhost отклоняется сразу — в интернет запрос не уходит.
    func testRequestUnreachableHostMapsToTransportError() async {
        do {
            let _: ReleaseResponse = try await client.request("http://127.0.0.1:1/release/1")
            XCTFail("ожидали APIError.transport для недоступного хоста")
        } catch {
            guard let apiError = error as? APIError else {
                return XCTFail("ожидали APIError, получили \(error)")
            }
            guard case .transport = apiError else {
                return XCTFail("ожидали APIError.transport, получили \(apiError)")
            }
        }
    }

    // MARK: Стенд MockURLProtocol

    /// Проверяет сам стенд: подменённая сессия перехватывает запрос, отдаёт тело,
    /// а тело разбирается декодером APIClient. Это заготовка для будущих тестов
    /// реальных запросов APIClient (токен, 401, коды ошибок).
    func testMockURLProtocolInterceptsRequest() async throws {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let url = URL(string: "https://example.invalid/release/1")!
        let body = Data(#"{"code":0,"release":{"id":1,"title_ru":"Тест"}}"#.utf8)
        var capturedURL: URL?
        MockURLProtocol.handler = { request in
            capturedURL = request.url
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(capturedURL?.absoluteString, "https://example.invalid/release/1")

        let decoded = try client.decoder.decode(ReleaseResponse.self, from: data)
        XCTAssertEqual(decoded.release.id, 1)
        XCTAssertEqual(decoded.release.displayTitle, "Тест")
    }
}
