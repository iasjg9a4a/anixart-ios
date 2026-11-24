import XCTest
import Foundation
@testable import Anixart

/// Разбор ссылок плееров: определение провайдера, YouTube-id, вид таргета, ошибки
/// и декодирование ответа `episode/target`.
final class PlaybackTests: XCTestCase {

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    private func makeEpisode(url: String?, iframe: Bool? = nil) -> Episode {
        Episode(
            position: 1,
            releaseId: 1,
            sourceId: 8,
            name: "1 серия",
            url: url,
            iframe: iframe,
            quality: 720,
            addedDate: nil,
            isWatched: false,
            isFiller: false
        )
    }

    // MARK: - 1. Определение провайдера

    func testProviderDetection() {
        // По имени источника — регистр не важен.
        XCTAssertEqual(VideoProvider.detect(sourceName: "Kodik", url: nil), .kodik)
        XCTAssertEqual(VideoProvider.detect(sourceName: "Sibnet", url: nil), .sibnet)
        XCTAssertEqual(VideoProvider.detect(sourceName: "Libria", url: nil), .libria)
        XCTAssertEqual(VideoProvider.detect(sourceName: "AniLibria", url: nil), .libria)
        XCTAssertEqual(VideoProvider.detect(sourceName: "Liberty", url: nil), .libria)
        XCTAssertEqual(VideoProvider.detect(sourceName: "RuTube", url: nil), .rutube)
        XCTAssertEqual(VideoProvider.detect(sourceName: "AnixPlayer", url: nil), .anixplayer)
        XCTAssertEqual(VideoProvider.detect(sourceName: "studiomir", url: nil), .anixplayer)
        XCTAssertEqual(VideoProvider.detect(sourceName: "YouTube", url: nil), .youtube)
        XCTAssertEqual(VideoProvider.detect(sourceName: "Неизвестный сервер", url: nil), .unknown)

        // По host ссылки, если имя источника не опознано.
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://kodikplayer.com/seria/1/abc/720p?d=1&s=2")), .kodik)
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://video.sibnet.ru/shell.php?videoid=123")), .sibnet)
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://anixart.libria.fun/index.php?m=release&id=1&serie=1")), .libria)
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://rutube.ru/video/abc/")), .rutube)
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://api.studiomir.club/video/1.m3u8")), .anixplayer)
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://youtu.be/dQw4w9WgXcQ")), .youtube)
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: makeURL("https://KODIKPLAYER.COM/x")), .kodik,
                       "host сравнивается без учёта регистра")

        // Имя источника приоритетнее ссылки: сервер может подсунуть какой угодно URL.
        XCTAssertEqual(VideoProvider.detect(sourceName: "Sibnet", url: makeURL("https://kodikplayer.com/x")), .sibnet)

        // Ни имени, ни ссылки — провайдер неизвестен.
        XCTAssertEqual(VideoProvider.detect(sourceName: nil, url: nil), .unknown)
        XCTAssertEqual(VideoProvider.detect(sourceName: "", url: makeURL("https://example.com/stream.m3u8")), .unknown)
    }

    // MARK: - 2. YouTube videoId

    func testYouTubeVideoIdExtraction() {
        let expectedId = "dQw4w9WgXcQ"
        let links = [
            "https://www.youtube.com/watch?v=\(expectedId)",
            "https://youtu.be/\(expectedId)",
            "https://www.youtube.com/embed/\(expectedId)",
            "https://youtube.com/shorts/\(expectedId)"
        ]

        for link in links {
            XCTAssertEqual(PlaybackResolver.videoId(from: makeURL(link)), expectedId,
                           "Не извлекли videoId из \(link)")
        }

        // Не-YouTube и ссылки без идентификатора videoId не дают.
        XCTAssertNil(PlaybackResolver.videoId(from: makeURL("https://example.com/watch?v=\(expectedId)")))
        XCTAssertNil(PlaybackResolver.videoId(from: makeURL("https://www.youtube.com/watch")))
        XCTAssertNil(PlaybackResolver.videoId(from: makeURL("https://www.youtube.com/watch?v=")))
    }

    // MARK: - 3. Kodik-ссылка открывается как web-страница

    func testKodikURLIsWeb() throws {
        let kodikURL = makeURL("https://kodikplayer.com/seria/1/abc/720p?d=1&s=2")
        let episode = makeEpisode(url: kodikURL.absoluteString, iframe: true)

        let target = try PlaybackResolver.resolve(episode: episode, sourceName: "Kodik")

        // Прямой Kodik в WebView отдаёт 500: оригинальное приложение грузит его через
        // серверный прокси anixmirai.com/iframe?url=..., который вставляет iframe.
        guard case .web(let webURL) = target.kind else {
            return XCTFail("Kodik должен открываться как web-страница, получено: \(target.kind)")
        }
        XCTAssertEqual(webURL.host, "anixmirai.com", "Kodik идёт через прокси Anixart")
        XCTAssertTrue(webURL.absoluteString.contains("kodikplayer.com"),
                      "Исходная Kodik-ссылка должна быть в параметре url: \(webURL)")
        XCTAssertTrue(target.providerName.contains("Kodik"), "providerName: \(target.providerName)")
        XCTAssertEqual(target.referer, PlaybackResolver.anixmiraiReferer,
                       "Прокси-страница ожидает Referer anixmirai.com")
        XCTAssertEqual(target.title, episode.displayName)
    }

    func testProxiedURLAcceptsQuery() {
        let url = makeURL("https://kodikplayer.com/seria/1/abc/720p?d=1&s=2")
        let proxied = PlaybackResolver.proxied(url)

        XCTAssertNotNil(proxied)
        XCTAssertEqual(proxied?.host, "anixmirai.com")
        let queryItem = URLComponents(url: proxied!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })
        XCTAssertEqual(queryItem?.value, url.absoluteString, "Ссылка целиком уходит в параметр url")
    }

    // MARK: - 4. Прямой HLS-поток проигрывается нативно

    func testM3U8IsHLS() throws {
        let streamURL = makeURL("https://example.com/stream.m3u8")
        let episode = makeEpisode(url: streamURL.absoluteString)

        let target = try PlaybackResolver.resolve(episode: episode, sourceName: nil)

        XCTAssertEqual(target.kind, .hls(streamURL), "m3u8 — прямой поток, его играет AVPlayer")
        XCTAssertFalse(target.providerName.isEmpty)
    }

    // MARK: - 5. Описания ошибок PlaybackError

    func testPlaybackErrorDescriptions() {
        let errors: [PlaybackError] = [
            .emptyURL,
            .unsupportedProvider("Kodik"),
            .resolutionFailed("таймаут"),
            .playbackUnavailable
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "У \(error) пустое описание ошибки")
        }

        // В описание подставляются имя провайдера и причина, иначе пользователь не поймёт.
        XCTAssertTrue(PlaybackError.unsupportedProvider("Kodik").errorDescription?.contains("Kodik") == true)
        XCTAssertTrue(PlaybackError.resolutionFailed("таймаут").errorDescription?.contains("таймаут") == true)
        XCTAssertNotEqual(PlaybackError.emptyURL.errorDescription,
                          PlaybackError.playbackUnavailable.errorDescription)
    }

    // MARK: - 6. Декодирование episode/target

    func testEpisodeFromTarget() throws {
        let json = """
        {"code":0,"episode":{"position":1,"sourceId":8,"url":"https://kodikplayer.com/x","iframe":true}}
        """
        let response = try JSONDecoder().decode(EpisodeTargetResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.code, 0)
        let episode = try XCTUnwrap(response.episode)
        XCTAssertEqual(episode.position, 1)
        XCTAssertEqual(episode.sourceId, 8)
        XCTAssertEqual(episode.url, "https://kodikplayer.com/x")
        XCTAssertEqual(episode.iframe, true)
        XCTAssertEqual(episode.id, "8-1", "id серии — составной: sourceId-position")
        XCTAssertEqual(episode.displayName, "Серия 1")
    }
}
