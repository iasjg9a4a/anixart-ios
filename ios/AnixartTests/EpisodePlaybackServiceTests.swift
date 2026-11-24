import XCTest
import Foundation
@testable import Anixart

/// Чистые помощники полного резолва серии (`EpisodePlaybackService`).
///
/// Сам `resolve(...)` ходит в сеть (API, `ftor`, нативные резолверы), поэтому
/// тестами покрыта логика, от которой зависит выбор ветки: определение
/// провайдера по web-цели, разворачивание прокси Anixart и сборка нативной
/// цели Kodik из `KodikStream`.
final class EpisodePlaybackServiceTests: XCTestCase {

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    private func makeWebTarget(providerName: String,
                               url: String = "https://example.com/player") -> PlaybackTarget {
        PlaybackTarget(
            kind: .web(makeURL(url)),
            title: "1 серия",
            providerName: providerName,
            referer: nil
        )
    }

    // MARK: - 1. Провайдер web-цели

    func testProviderComesFromResolvedTargetName() {
        // `PlaybackResolver` кладёт в `providerName` человеческое имя источника,
        // поэтому по нему восстанавливается та же ветка нативного резолвера.
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "Kodik")), .kodik)
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "Sibnet")), .sibnet)
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "Libria")), .libria)
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "AniLibria")), .libria)
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "RuTube")), .rutube)
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "AnixPlayer")), .anixplayer)
        XCTAssertEqual(EpisodePlaybackService.provider(for: makeWebTarget(providerName: "Онлайн-плеер")), .unknown)
    }

    // MARK: - 2. Разворачивание прокси Anixart

    func testOriginalWebURLUnwrapsProxy() {
        // Libria и Kodik приходят обёрнутыми в `anixmirai.com/iframe?url=...`:
        // нативные резолверы ждут исходную страницу плеера, а не прокси.
        let proxy = "https://anixmirai.com/iframe?url="
            + "https%3A%2F%2Fkodikplayer.com%2Fseria%2F175268%2Fhash12345%2F720p"
        let target = makeWebTarget(providerName: "Kodik", url: proxy)

        XCTAssertEqual(
            EpisodePlaybackService.originalWebURL(for: target)?.absoluteString,
            "https://kodikplayer.com/seria/175268/hash12345/720p"
        )
    }

    func testOriginalWebURLKeepsDirectPage() {
        let direct = "https://video.sibnet.ru/shell.php?videoid=123"
        let target = makeWebTarget(providerName: "Sibnet", url: direct)

        XCTAssertEqual(
            EpisodePlaybackService.originalWebURL(for: target)?.absoluteString,
            direct
        )
    }

    func testOriginalWebURLIsNilForNativeTarget() {
        let target = PlaybackTarget(
            kind: .hls(makeURL("https://cdn.example.com/720.m3u8")),
            title: "1 серия",
            providerName: "AniLibria",
            referer: nil
        )

        XCTAssertNil(EpisodePlaybackService.originalWebURL(for: target))
    }

    func testUnwrappedProxyURLRejectsForeignLinks() {
        // Ссылка с параметром `url` на чужом хосте — не прокси Anixart.
        let foreign = makeURL("https://example.com/iframe?url=https%3A%2F%2Fkodikplayer.com%2Fseria%2F1%2Fhash12345%2F720p")
        XCTAssertNil(EpisodePlaybackService.unwrappedProxyURL(foreign))

        // Прокси без параметра `url` разворачивать нечего.
        let empty = makeURL("https://anixmirai.com/iframe")
        XCTAssertNil(EpisodePlaybackService.unwrappedProxyURL(empty))
    }

    // MARK: - 3. Нативная цель Kodik

    func testDirectTargetMapsBestStreamAndVariants() {
        let page = makeURL("https://kodikplayer.com/seria/175268/hash12345/720p")
        let url720 = makeURL("https://cloud2.solodcdn.com/a/720.mp4:hls:manifest.m3u8")
        let url480 = makeURL("https://cloud2.solodcdn.com/a/480.mp4:hls:manifest.m3u8")
        let stream = KodikStream(
            pageURL: page,
            qualities: ["720": url720, "480": url480],
            bestQuality: "720",
            bestURL: url720
        )

        let target = EpisodePlaybackService.directTarget(from: stream, title: "1 серия")

        XCTAssertEqual(target.kind, .hls(url720))
        XCTAssertEqual(target.providerName, "Kodik")
        XCTAssertEqual(target.referer, page)
        XCTAssertEqual(target.title, "1 серия")
        XCTAssertEqual(target.variants?.map(\.quality) ?? [], ["720p", "480p"])
        XCTAssertEqual(target.variants?.first?.url, Optional(url720))
    }
}
