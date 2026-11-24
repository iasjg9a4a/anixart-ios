import XCTest
@testable import Anixart

/// Регрессия на реальный баг: сервер отдаёт `sources[].type` либо объектом озвучки,
/// либо просто её id числом. Строгое декодирование роняло весь ответ
/// `episode/{releaseId}/{typeId}`, и из-за одного источника (Libria/Sibnet)
/// у озвучки пропадали все плееры — пользователь видел «только Kodik».
final class EpisodeSourceDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testEpisodeTypeDecodesFromObject() throws {
        let json = """
        {"@id": 2, "id": 2, "name": "AniLibria", "icon": "https://s3.anixmirai.com/voiceovers/anilibria.jpg",
         "workers": "", "is_sub": false, "episodes_count": 0}
        """
        let type = try decode(EpisodeType.self, json)
        XCTAssertEqual(type.id, 2)
        XCTAssertEqual(type.name, "AniLibria")
        XCTAssertEqual(type.isSub, false)
        XCTAssertEqual(type.displayName, "AniLibria")
    }

    func testEpisodeTypeDecodesFromInteger() throws {
        let type = try decode(EpisodeType.self, "2")
        XCTAssertEqual(type.id, 2)
        XCTAssertNil(type.name)
        XCTAssertNil(type.isSub)
        XCTAssertEqual(type.displayName, "Озвучка")
    }

    func testEpisodeSourcesDecodesMixedTypeShapes() throws {
        // Реальный ответ `episode/92/1`: Sibnet с объектом, Kodik с числом.
        let json = """
        {"code": 0, "sources": [
          {"@id": 1, "id": 1, "type": {"@id": 2, "id": 1, "name": "AniDUB", "is_sub": false, "episodes_count": 0},
           "name": "Sibnet", "episodes_count": 25, "quality": 0},
          {"@id": 3, "id": 8, "type": 2, "name": "Kodik", "episodes_count": 24, "quality": 0}
        ]}
        """
        let response = try decode(EpisodeSourcesResponse.self, json)
        XCTAssertEqual(response.code, 0)
        let sources = try XCTUnwrap(response.sources)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.map(\.id), [1, 8])
        XCTAssertEqual(sources.map(\.displayName), ["Sibnet", "Kodik"])
        XCTAssertEqual(sources.first?.episodesCount, 25)
        XCTAssertEqual(sources.last?.type?.id, 2)
        XCTAssertEqual(sources.first?.type?.name, "AniDUB")
    }

    func testEpisodeSourcesDecodesLibriaIntegerType() throws {
        // Реальный ответ `episode/92/2`: Libria с `"type": 2`.
        let json = """
        {"code": 0, "sources": [
          {"@id": 1, "id": 7, "type": {"@id": 2, "id": 2, "name": "AniLibria", "is_sub": false},
           "name": "Kodik", "episodes_count": 24, "quality": 0},
          {"@id": 3, "id": 218, "type": 2, "name": "Libria", "episodes_count": 24, "quality": 0,
           "download_speed_limit": 512}
        ]}
        """
        let response = try decode(EpisodeSourcesResponse.self, json)
        let sources = try XCTUnwrap(response.sources)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.last?.name, "Libria")
        XCTAssertEqual(sources.last?.type?.id, 2)
        XCTAssertEqual(sources.last?.episodesCount, 24)
    }

    func testEpisodeSourcesToleratesUnknownFields() throws {
        let json = """
        {"code": 0, "sources": [
          {"id": 9, "type": 3, "name": "RuTube", "episodes_count": 12, "quality": 0,
           "is_download_disabled": true, "download_speed_limit": 0, "brand_new_field": {"x": [1, 2, 3]}}
        ]}
        """
        let response = try decode(EpisodeSourcesResponse.self, json)
        XCTAssertEqual(response.sources?.first?.name, "RuTube")
        XCTAssertEqual(response.sources?.first?.type?.id, 3)
    }
}
