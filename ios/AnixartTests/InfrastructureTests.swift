import XCTest
import Foundation
@testable import Anixart

// MARK: - Вспомогательное

/// Счётчик вызовов операции в `Retry.run`: ссылочный тип, чтобы замыкание
/// меняло одно общее состояние, а не копировало локальную переменную.
private final class CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// Нейтральная ошибка без собственной классификации ретраибельности.
private struct StubError: Error {}

// MARK: - Повторы, коды API, deep links

/// Инфраструктура без сети: политика повторов, классификация ошибок,
/// `APIClient.check` и разбор deep links.
final class InfrastructureTests: XCTestCase {

    /// Нулевая пауза: тест проверяет число попыток, а не выдержку перед ними.
    private var fastPolicy: RetryPolicy {
        RetryPolicy(maxAttempts: 3, initialDelay: 0, multiplier: 1, jitter: 0)
    }

    // MARK: - 1. RetryPolicy

    func testRetryPolicyAttempts() async throws {
        XCTAssertEqual(RetryPolicy.default.maxAttempts, 3, "обычные запросы — до трёх попыток")
        XCTAssertEqual(RetryPolicy.none.maxAttempts, 1, "операции без повторов — одна попытка")
        XCTAssertEqual(RetryPolicy.aggressive.maxAttempts, 5)
    }

    func testRetryPolicyDelayGrowsExponentially() async throws {
        let policy = RetryPolicy.default
        let first = policy.delay(afterAttempt: 0)
        let second = policy.delay(afterAttempt: 1)
        let third = policy.delay(afterAttempt: 2)

        XCTAssertLessThan(first, second, "пауза перед вторым повтором больше первой")
        XCTAssertLessThan(second, third, "пауза перед третьим повтором больше второй")
        // Даже верхняя граница jitter не перекрывает следующий шаг экспоненты.
        XCTAssertLessThan(first, policy.initialDelay * policy.multiplier)
        XCTAssertGreaterThanOrEqual(third, policy.initialDelay * pow(policy.multiplier, 2))
    }

    func testRetryPolicyJitterStaysWithinBounds() async throws {
        let policy = RetryPolicy.default
        for attempt in 0..<4 {
            let base = policy.initialDelay * pow(policy.multiplier, Double(attempt))
            let upper = base * (1 + policy.jitter)
            for _ in 0..<50 {
                let delay = policy.delay(afterAttempt: attempt)
                XCTAssertGreaterThanOrEqual(delay, base - 1e-9,
                                            "случайная добавка не уменьшает задержку")
                XCTAssertLessThanOrEqual(delay, upper + 1e-9,
                                         "jitter не превышает \(policy.jitter) от базы")
            }
        }
    }

    func testRetryPolicyZeroJitterIsDeterministic() async throws {
        let policy = RetryPolicy(maxAttempts: 4, initialDelay: 0.5, multiplier: 3, jitter: 0)
        XCTAssertEqual(policy.delay(afterAttempt: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(afterAttempt: 2), 4.5, accuracy: 1e-9)
        // Отрицательный номер попытки трактуется как первая.
        XCTAssertEqual(policy.delay(afterAttempt: -3), 0.5, accuracy: 1e-9)
        // У политики без повторов паузы нет вовсе.
        XCTAssertEqual(RetryPolicy.none.delay(afterAttempt: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(RetryPolicy.none.delay(afterAttempt: 5), 0, accuracy: 1e-9)
    }

    // MARK: - 2. Retry.run

    func testRetryRunSucceedsOnThirdAttempt() async throws {
        let counter = CallCounter()

        let result = try await Retry.run(fastPolicy) { () async throws -> String in
            counter.increment()
            if counter.count < 3 {
                throw StubError()
            }
            return "ответ"
        }

        XCTAssertEqual(result, "ответ")
        XCTAssertEqual(counter.count, 3, "операция вызвана ровно три раза")
    }

    func testRetryRunExhaustsAttemptsAndThrowsLastError() async throws {
        let counter = CallCounter()

        do {
            _ = try await Retry.run(fastPolicy) { () async throws -> Int in
                counter.increment()
                throw APIError.api(counter.count)
            }
            XCTFail("операция не могла завершиться успешно")
        } catch {
            XCTAssertEqual(error as? APIError, .api(3), "наружу уходит ошибка последней попытки")
        }
        XCTAssertEqual(counter.count, 3)
    }

    func testRetryRunDoesNotRetryCancellation() async throws {
        let counter = CallCounter()

        do {
            _ = try await Retry.run(fastPolicy) { () async throws -> Int in
                counter.increment()
                throw CancellationError()
            }
            XCTFail("отменённую операцию нельзя выполнить успешно")
        } catch {
            XCTAssertTrue(error is CancellationError, "ожидали CancellationError, получили \(error)")
        }
        XCTAssertEqual(counter.count, 1, "отмену не повторяем ни при каких настройках")
    }

    func testRetryRunStopsOnNonRetryableError() async throws {
        let counter = CallCounter()

        do {
            _ = try await Retry.run(fastPolicy, isRetryable: Retry.isRetryable) { () async throws -> Int in
                counter.increment()
                throw APIError.unauthorized
            }
            XCTFail("401 не должен приводить к успеху")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertEqual(counter.count, 1, "неретраибельная ошибка не повторяется")
    }

    func testRetryRunRetriesTransportError() async throws {
        let counter = CallCounter()

        let result = try await Retry.run(fastPolicy, isRetryable: Retry.isRetryable) { () async throws -> String in
            counter.increment()
            if counter.count < 3 {
                throw APIError.transport("обрыв связи")
            }
            return "ок"
        }

        XCTAssertEqual(result, "ок")
        XCTAssertEqual(counter.count, 3, "транспортная ошибка ретраится")
    }

    // MARK: - 3. APIError + RetryableError

    func testRetryableErrorClassification() async throws {
        XCTAssertTrue(Retry.isRetryable(APIError.transport("обрыв связи")), "сетевой сбой повторяем")
        XCTAssertFalse(Retry.isRetryable(APIError.unauthorized), "401 повторять бессмысленно")
        XCTAssertFalse(Retry.isRetryable(APIError.api(2)), "логическая ошибка API не повторяется")

        // HTTP-коды: 5xx и 429 — можно, остальные 4xx — нет.
        XCTAssertTrue(Retry.isRetryable(APIError.http(500)))
        XCTAssertTrue(Retry.isRetryable(APIError.http(429)))
        XCTAssertFalse(Retry.isRetryable(APIError.http(404)))
        XCTAssertFalse(Retry.isRetryable(APIError.decoding("формат ответа")))

        // Незнакомая ошибка ретраибельной не считается.
        XCTAssertFalse(Retry.isRetryable(StubError()))

        // Та же классификация доступна через протокол.
        let transport: RetryableError = APIError.transport("таймаут")
        XCTAssertTrue(transport.isRetryable)
    }

    // MARK: - 4. APIClient.check

    func testCheckAcceptsSuccessCodes() async throws {
        let client = APIClient.shared
        XCTAssertNoThrow(try client.check(0), "код 0 — штатный успех")
        XCTAssertNoThrow(try client.check(2, success: [0, 2, 3]), "2 входит в success")
        XCTAssertNoThrow(try client.check(3, success: [0, 2, 3]))
    }

    func testCheck401ThrowsUnauthorized() async throws {
        XCTAssertThrowsError(try APIClient.shared.check(401)) { error in
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
    }

    func testCheckUnknownCodeThrowsAPIError() async throws {
        XCTAssertThrowsError(try APIClient.shared.check(5)) { error in
            XCTAssertEqual(error as? APIError, .api(5))
        }
        // Без явного success код 2 — тоже ошибка API.
        XCTAssertThrowsError(try APIClient.shared.check(2)) { error in
            XCTAssertEqual(error as? APIError, .api(2))
        }
    }

    // MARK: - 5. DeepLinkRouter

    private func assertRoute(_ link: String,
                             equals expected: AppRoute,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let url = URL(string: link) else {
            return XCTFail("Не удалось построить URL: \(link)", file: file, line: line)
        }
        let route: AppRoute? = DeepLinkRouter.route(for: url)
        XCTAssertEqual(route, Optional(expected), "ссылка \(link)", file: file, line: line)
    }

    private func assertNoRoute(_ link: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        guard let url = URL(string: link) else {
            return XCTFail("Не удалось построить URL: \(link)", file: file, line: line)
        }
        XCTAssertNil(DeepLinkRouter.route(for: url), "ссылка должна игнорироваться: \(link)",
                     file: file, line: line)
    }

    func testDeepLinkRoutesKnownPaths() async throws {
        assertRoute("anixart://release/123", equals: .release(id: 123))
        assertRoute("anixart://profile/42", equals: .profile(id: 42))
        assertRoute("anixart://collection/7", equals: .collection(id: 7))
        assertRoute("anixart://search?q=naruto", equals: .search(query: "naruto"))
        assertRoute("anixart://history", equals: .history)
        // Universal links используют те же пути, что и кастомная схема.
        assertRoute("https://anixart-app.com/release/123", equals: .release(id: 123))
        assertRoute("https://www.anixart.link/profile/42", equals: .profile(id: 42))
    }

    func testDeepLinkRejectsGarbage() async throws {
        assertNoRoute("anixart://release/abc")       // id не число
        assertNoRoute("anixart://release/0")         // id должен быть положительным
        assertNoRoute("anixart://unknown/1")         // неизвестный путь
        assertNoRoute("anixart://search")            // нет параметра q
        assertNoRoute("anixart://search?q=%20")      // q из одних пробелов
        assertNoRoute("https://example.com")         // чужой домен universal link
        assertNoRoute("anixart://history/extra")     // лишний сегмент у history
    }
}

// MARK: - Дисковый кэш и прогресс просмотра

/// Локальные хранилища: офлайн-кэш, прогресс просмотра и кэш изображений.
/// Все тесты работают с симуляторными каталогами и `UserDefaults`, без сети.
final class StorageTests: XCTestCase {

    // MARK: - 6. OfflineIntegration

    func testOfflineIntegrationCatalogRoundTrip() async throws {
        // Чистим диск, чтобы результат не зависел от прошлых прогонов.
        await OfflineCache.shared.clear()

        let json = #"[{"id":1,"title_ru":"Тест"},{"id":2,"title_ru":"Второй"}]"#
        let releases = try JSONDecoder().decode([Release].self, from: Data(json.utf8))

        let page = 904_201
        await OfflineIntegration.storeCatalog(releases, page: page, totalCount: releases.count)

        let loaded = await OfflineIntegration.cachedCatalog(page: page)
        let cached = try XCTUnwrap(loaded, "Свежий каталог должен читаться с диска")
        XCTAssertEqual(cached.map(\.id), [1, 2], "порядок и id сохраняются")
        XCTAssertEqual(cached.first?.titleRu, "Тест")

        // Пустая страница не кэшируется, а страница без кэша — nil.
        let emptyPage = await OfflineIntegration.cachedCatalog(page: page + 1)
        XCTAssertNil(emptyPage)

        // Полная карточка релиза хранится отдельным ключом.
        let first = try XCTUnwrap(cached.first)
        await OfflineIntegration.storeRelease(first)
        let storedRelease = await OfflineIntegration.cachedRelease(id: first.id)
        XCTAssertEqual(storedRelease?.id, first.id)
        XCTAssertEqual(storedRelease?.titleRu, "Тест")

        // TTL: отрицательный maxAge — данные уже не считаются свежими.
        let expired = await OfflineCache.shared.load(Release.self,
                                                    for: CacheKey.release(id: first.id),
                                                    maxAge: -1)
        XCTAssertNil(expired, "просроченный кэш не отдаётся")

        await OfflineCache.shared.clear()
    }

    // MARK: - 7. PlaybackProgress

    @MainActor
    func testPlaybackProgressSavesAndReadsPosition() async throws {
        let releaseId = 987_654_321
        let sourceId = 12
        let position = 3
        let playbackKey = PlaybackKey(releaseId: releaseId, sourceId: sourceId, position: position)
        let key = playbackKey.storageKey

        XCTAssertEqual(key, "987654321-12-3", "ключ строится из releaseId-sourceId-position")
        XCTAssertEqual(PlaybackKey(storageKey: key), Optional(playbackKey), "storageKey разбирается обратно")

        let defaults = UserDefaults.standard
        let valueKey = "anixart.playback." + key
        let dateKey = "anixart.playback.date." + key
        let indexKey = "anixart.playback.index"

        // Следов прошлого прогона быть не должно.
        defaults.removeObject(forKey: valueKey)
        defaults.removeObject(forKey: dateKey)
        if var keys = defaults.stringArray(forKey: indexKey) {
            keys.removeAll { $0 == key }
            defaults.set(keys, forKey: indexKey)
        }

        defer {
            defaults.removeObject(forKey: valueKey)
            defaults.removeObject(forKey: dateKey)
            if var keys = defaults.stringArray(forKey: indexKey) {
                keys.removeAll { $0 == key }
                if keys.isEmpty {
                    defaults.removeObject(forKey: indexKey)
                } else {
                    defaults.set(keys, forKey: indexKey)
                }
            }
        }

        // shared создаётся здесь: позиции загружаются из UserDefaults уже после очистки.
        let progress = PlaybackProgress.shared
        XCTAssertNil(progress.position(releaseId: releaseId, sourceId: sourceId, position: position),
                     "до сохранения позиции нет")

        progress.savePosition(seconds: 42, releaseId: releaseId, sourceId: sourceId, position: position)
        XCTAssertEqual(progress.position(releaseId: releaseId, sourceId: sourceId, position: position), 42)
        XCTAssertEqual(progress.lastPlayed[key], 42, "позиция попадает в память сервиса")
        XCTAssertEqual(defaults.object(forKey: valueKey) as? Int, 42, "и в UserDefaults")

        // Отрицательная позиция приводится к нулю.
        progress.savePosition(seconds: -10, releaseId: releaseId, sourceId: sourceId, position: position)
        XCTAssertEqual(progress.position(releaseId: releaseId, sourceId: sourceId, position: position), 0)

        // Соседняя серия хранится отдельно и ещё не смотрелась.
        let otherEpisode = 4
        XCTAssertNotEqual(PlaybackKey(releaseId: releaseId, sourceId: sourceId, position: otherEpisode).storageKey, key)
        XCTAssertNil(progress.position(releaseId: releaseId, sourceId: sourceId, position: otherEpisode))
    }

    // MARK: - 8. ImageCache

    /// `store` кладёт данные в память, `imageData` отдаёт их без сети.
    /// Домен `example.invalid` заведомо недоступен: сетевая ветка не должна сработать.
    func testImageCacheReturnsStoredDataWithoutNetwork() async throws {
        let cache = ImageCache.shared
        let url = try XCTUnwrap(URL(string: "https://example.invalid/anixart-\(UUID().uuidString).png"))
        let data = Data("локальные байты".utf8)

        await cache.store(data, for: url)
        let loaded = await cache.imageData(for: url)
        XCTAssertEqual(loaded, data, "данные из памяти отдаются без запроса в сеть")

        await cache.clear()
    }
}
