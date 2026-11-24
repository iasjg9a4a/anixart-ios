import XCTest
import Foundation
@testable import Anixart

/// Кэш резолва серий (`EpisodeResolutionCache`) — тот, за счёт которого
/// «Следующая серия» переключается без ожидания сети.
///
/// Сам резолв ходит в сеть (`episode/target` + нативные резолверы), поэтому
/// здесь проверяется ровно то, от чего зависит скорость и корректность:
/// ключ серии, время жизни записи (подписанные ссылки истекают), вытеснение,
/// сброс для кнопки «Повторить» и дедупликация подогрева.
final class EpisodeResolutionCacheTests: XCTestCase {

    // MARK: - Вспомогательные

    private func makeResolution(sourceId: Int = 8,
                                url: String = "https://cdn.example.com/stream.m3u8") -> EpisodeResolution {
        guard let streamURL = URL(string: url) else {
            XCTFail("Некорректный URL в тесте: \(url)")
            return EpisodeResolution(
                target: PlaybackTarget(kind: .web(URL(fileURLWithPath: "/")),
                                       title: "",
                                       providerName: "",
                                       referer: nil),
                sourceId: sourceId,
                sourceName: nil
            )
        }
        return EpisodeResolution(
            target: PlaybackTarget(
                kind: .hls(streamURL),
                title: "1 серия",
                providerName: "Kodik",
                referer: nil
            ),
            sourceId: sourceId,
            sourceName: nil
        )
    }

    // MARK: - 1. Ключ серии

    func testKeyIncludesReleaseSourceAndPosition() {
        // Позиции уникальны только внутри источника: без sourceId в ключе
        // «3 серия» из разных озвучек схлопнулась бы в одну запись.
        XCTAssertEqual(EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 3), "1-8-3")
        XCTAssertNotEqual(
            EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 3),
            EpisodeResolutionCache.key(releaseId: 1, sourceId: 9, position: 3)
        )
        XCTAssertNotEqual(
            EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 3),
            EpisodeResolutionCache.key(releaseId: 2, sourceId: 8, position: 3)
        )
    }

    // MARK: - 2. Чтение и запись

    func testStoredResolutionIsReturnedWhileFresh() async {
        let cache = EpisodeResolutionCache(lifetime: 60, limit: 4)
        let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 1)
        let now = Date()

        await cache.store(makeResolution(), forKey: key, at: now)

        let cached = await cache.resolution(forKey: key, at: now.addingTimeInterval(59))
        XCTAssertEqual(cached, makeResolution())
    }

    func testMissingKeyReturnsNil() async {
        let cache = EpisodeResolutionCache(lifetime: 60, limit: 4)
        let cached = await cache.resolution(forKey: "нет такой серии", at: Date())
        XCTAssertNil(cached)
    }

    // MARK: - 3. Время жизни

    func testExpiredResolutionIsNotReturned() async {
        // Ссылка `episode/target` подписана и живёт ограниченное время: отдать
        // её через полчаса — это «вечная загрузка» вместо серии.
        let cache = EpisodeResolutionCache(lifetime: 60, limit: 4)
        let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 1)
        let now = Date()

        await cache.store(makeResolution(), forKey: key, at: now)

        let expired = await cache.resolution(forKey: key, at: now.addingTimeInterval(61))
        XCTAssertNil(expired)
    }

    func testClockSkewDoesNotRevivePastEntries() async {
        // Часы могли уехать назад (смена таймзоны, синхронизация времени):
        // отрицательный «возраст» записи не должен считаться свежестью.
        let cache = EpisodeResolutionCache(lifetime: 60, limit: 4)
        let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 1)
        let now = Date()

        await cache.store(makeResolution(), forKey: key, at: now)

        let shifted = await cache.resolution(forKey: key, at: now.addingTimeInterval(-10))
        XCTAssertNil(shifted)
    }

    // MARK: - 4. Вытеснение

    func testOldestEntriesAreEvictedBeyondLimit() async {
        let cache = EpisodeResolutionCache(lifetime: 600, limit: 2)
        let now = Date()

        for position in 1...3 {
            let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: position)
            await cache.store(makeResolution(), forKey: key, at: now.addingTimeInterval(Double(position)))
        }

        let keys = await cache.cachedKeys()
        XCTAssertEqual(keys, ["1-8-2", "1-8-3"], "в кэше должны остаться две самые свежие серии")
    }

    // MARK: - 5. Сброс записи («Повторить»)

    func testInvalidateDropsEntry() async {
        let cache = EpisodeResolutionCache(lifetime: 600, limit: 4)
        let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 1)
        let now = Date()

        await cache.store(makeResolution(), forKey: key, at: now)
        await cache.invalidate(forKey: key)

        let cached = await cache.resolution(forKey: key, at: now)
        XCTAssertNil(cached, "после сброса серия должна резолвиться заново")
    }

    // MARK: - 6. Дедупликация подогрева

    func testPrefetchIsNotStartedTwiceForSameEpisode() async {
        let cache = EpisodeResolutionCache(lifetime: 600, limit: 4)
        let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 2)

        let first = await cache.beginPrefetch(forKey: key)
        let second = await cache.beginPrefetch(forKey: key)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "второй подогрев той же серии не должен ходить в сеть")

        await cache.endPrefetch(forKey: key)
        let afterEnd = await cache.beginPrefetch(forKey: key)
        XCTAssertTrue(afterEnd, "после завершения подогрев можно повторить")
    }

    func testPrefetchIsSkippedWhenFreshResolutionExists() async {
        let cache = EpisodeResolutionCache(lifetime: 600, limit: 4)
        let key = EpisodeResolutionCache.key(releaseId: 1, sourceId: 8, position: 2)
        let now = Date()

        await cache.store(makeResolution(), forKey: key, at: now)

        let started = await cache.beginPrefetch(forKey: key, at: now)
        XCTAssertFalse(started, "серия уже подогрета — сетевые запросы не нужны")

        let afterExpiry = await cache.beginPrefetch(forKey: key, at: now.addingTimeInterval(601))
        XCTAssertTrue(afterExpiry, "истёкшую запись подогреваем заново")
    }
}
