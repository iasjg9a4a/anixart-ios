import XCTest
import Foundation
@testable import Anixart

/// Проверка того, что Codable-модели разбирают настоящие ответы API.
///
/// Фикстуры — реальные ответы сервера из `tools/fixtures` (скачиваются
/// `tools/fetch_fixtures.py`). Контракт с живым API отдельно проверяет
/// `tools/ModelCheck`, поэтому здесь нет сети: только декодирование.
final class ModelsDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Фикстуры

    /// Каталог с JSON-фикстурами.
    ///
    /// `#filePath` указывает на `<repo>/ios/AnixartTests/ModelsDecodingTests.swift`,
    /// поэтому после двух `deletingLastPathComponent()` получаем `<repo>/ios`,
    /// откуда фикстуры лежат в `tools/fixtures`. Второй кандидат нужен на случай,
    /// если тесты положат рядом с `<repo>/ios`, а не внутрь него, — путь не зависит
    /// от рабочей директории и от того, откуда запущен `xcodebuild`.
    private static var fixturesDirectory: URL {
        let iosDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // <repo>/ios/AnixartTests
            .deletingLastPathComponent()   // <repo>/ios

        let candidates = [
            iosDirectory.appendingPathComponent("tools/fixtures"),
            iosDirectory.appendingPathComponent("ios/tools/fixtures")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent(name))
    }

    private func decode<T: Decodable>(_ type: T.Type, from file: String) throws -> T {
        try decoder.decode(type, from: data(file))
    }

    // MARK: - Релиз, профиль, каталог

    func testReleaseDecodes() throws {
        let response = try decode(ReleaseResponse.self, from: "release.json")

        XCTAssertEqual(response.code, 0)
        let release = response.release
        XCTAssertFalse(release.displayTitle.isEmpty)
        XCTAssertGreaterThan(release.genreList.count, 0)
        XCTAssertNotNil(release.episodesTotal)
        XCTAssertTrue((release.comments?.count ?? 0) > 0)
        XCTAssertTrue((release.relatedReleases?.count ?? 0) > 0)
    }

    func testProfileDecodes() throws {
        let response = try decode(ProfileResponse.self, from: "profile.json")

        XCTAssertEqual(response.code, 0)
        XCTAssertEqual(response.profile.displayName, "Anixart")
        XCTAssertNotNil(response.profile.watchingCount)
    }

    func testPagedCatalog() throws {
        let page = try decode(Paged<Release>.self, from: "filter.json")

        XCTAssertEqual(page.code, 0)
        XCTAssertEqual(page.content.count, 25, "filter.json — одна страница каталога")
        XCTAssertNotNil(page.totalCount)
    }

    func testDiscover() throws {
        let hub = try decode(Discover.self, from: "discover.json")

        XCTAssertEqual(hub.code, 0)
        XCTAssertTrue((hub.watching?.count ?? 0) > 0)
        XCTAssertTrue((hub.interesting?.count ?? 0) > 0)
    }

    func testSearch() throws {
        let page = try decode(Paged<Release>.self, from: "search.json")

        XCTAssertEqual(page.code, 0)
        XCTAssertFalse(page.content.isEmpty)
    }

    // MARK: - Озвучки, источники, серии

    func testEpisodeTypes() throws {
        let response = try decode(EpisodeTypesResponse.self, from: "episode_types.json")

        XCTAssertEqual(response.code, 0)
        let types = try XCTUnwrap(response.types)
        XCTAssertFalse(types.isEmpty)
        let first = try XCTUnwrap(types.first)
        XCTAssertFalse(first.displayName.isEmpty)
        XCTAssertNotNil(first.isSub)
        XCTAssertNotNil(first.episodesCount)
    }

    func testEpisodeSources() throws {
        let response = try decode(EpisodeSourcesResponse.self, from: "episode_sources.json")

        XCTAssertEqual(response.code, 0)
        let sources = try XCTUnwrap(response.sources)
        XCTAssertFalse(sources.isEmpty)
        let first = try XCTUnwrap(sources.first)
        XCTAssertFalse(first.displayName.isEmpty)
        XCTAssertNotNil(first.type)
        XCTAssertNotNil(first.episodesCount)
    }

    func testEpisodes() throws {
        let response = try decode(EpisodesResponse.self, from: "episodes.json")

        XCTAssertEqual(response.code, 0)
        let episodes = try XCTUnwrap(response.episodes)
        XCTAssertFalse(episodes.isEmpty)
        let first = try XCTUnwrap(episodes.first)
        XCTAssertGreaterThan(first.position, 0)
        XCTAssertNotNil(first.url)
        XCTAssertNotNil(first.iframe)
    }

    func testEpisodeTarget() throws {
        let response = try decode(EpisodeTargetResponse.self, from: "episode_target.json")

        XCTAssertEqual(response.code, 0)
        let episode = try XCTUnwrap(response.episode)
        XCTAssertGreaterThan(episode.position, 0)
        XCTAssertNotNil(episode.url)
        XCTAssertNotNil(episode.iframe)
        XCTAssertNotNil(episode.sourceId)
    }

    // MARK: - Устойчивость и краевые случаи

    func testPagedToleratesEmptyBody() throws {
        // Сервер иногда отвечает `{"code": 0}` без списка — это не ошибка декодирования.
        let page = try decoder.decode(Paged<Release>.self, from: Data("{\"code\":0}".utf8))

        XCTAssertEqual(page.code, 0)
        XCTAssertTrue(page.content.isEmpty)
    }

    func testEpisodeCompositeId() {
        // position сам по себе не уникален: серии приходят из разных источников.
        let first = Episode(position: 1, releaseId: nil, sourceId: 8, name: nil,
                            url: nil, iframe: nil, quality: nil, addedDate: nil,
                            isWatched: nil, isFiller: nil)
        let second = Episode(position: 1, releaseId: nil, sourceId: 9, name: nil,
                             url: nil, iframe: nil, quality: nil, addedDate: nil,
                             isWatched: nil, isFiller: nil)

        XCTAssertEqual(first.position, second.position)
        XCTAssertNotEqual(first.sourceId, second.sourceId)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testSignInResponseShape() throws {
        let json = Data("{\"code\":0,\"profile\":null,\"profileToken\":{\"id\":1,\"token\":\"abc\"}}".utf8)
        let response = try decoder.decode(AuthResponse.self, from: json)

        XCTAssertEqual(response.code, 0)
        XCTAssertNil(response.profile)
        XCTAssertEqual(response.profileToken?.id, 1)
        XCTAssertEqual(response.profileToken?.token, "abc")
    }
}
