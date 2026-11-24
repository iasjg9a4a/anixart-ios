import XCTest
import Foundation
@testable import Anixart

/// Качество во всех нативных резолверах — `PlaybackTarget.variants` / `PlaybackVariant`.
///
/// Только чистые функции, без сети: разбор `ftor`, JSON AniLibria, ответа StudioMir и
/// master-плейлиста RuTube. Данные взяты из живых ответов 24.11.2026:
///
/// * Kodik `ftor` (`seria/175268`): качества `360`, `480`, `720` — без `1080`;
/// * AniLibria `anime/releases/1243`: `hls_480` и `hls_720`, `hls_1080: null`;
/// * StudioMir `ani=1`: `hls.1080p` и `hls.720p`, `2160p` — пустая строка;
/// * RuTube master: `1920x1080`, `1280x720`, `848x476`, `640x360`, `426x240`, `256x144` —
///   по два зеркала (CDN `rtbcdn.ru` и `river-1.rutube.ru`) на каждое разрешение.
final class QualityVariantsTests: XCTestCase {

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    private func labels(_ variants: [PlaybackVariant]) -> [String] {
        variants.map(\.quality)
    }

    // MARK: - 1. Kodik: варианты из словаря `ftor`

    func testKodikVariantsSortedBestFirst() {
        let qualities: [String: URL] = [
            "360": makeURL("https://cdn.example/360.m3u8"),
            "720": makeURL("https://cdn.example/720.m3u8"),
            "480": makeURL("https://cdn.example/480.m3u8")
        ]
        let variants = KodikDirectResolver.variants(from: qualities)

        XCTAssertEqual(labels(variants), ["720p", "480p", "360p"])
        XCTAssertEqual(variants.first?.url.absoluteString, "https://cdn.example/720.m3u8")
        XCTAssertEqual(variants.count, 3)
    }

    func testKodikVariantsMatchStreamAndBestQuality() throws {
        let url360 = makeURL("https://cdn.example/360.m3u8")
        let url720 = makeURL("https://cdn.example/720.m3u8")
        let url1080 = makeURL("https://cdn.example/1080.m3u8")
        let stream = KodikStream(
            pageURL: makeURL("https://kodikplayer.com/seria/1/abcdef0123456789/720p"),
            qualities: ["360": url360, "720": url720, "1080": url1080],
            bestQuality: "1080",
            bestURL: url1080
        )

        let variants = KodikDirectResolver.variants(for: stream)

        XCTAssertEqual(labels(variants), ["1080p", "720p", "360p"])
        // Первый вариант — то, что играет AVPlayer сейчас: меню открывается на текущем качестве.
        XCTAssertEqual(variants.first?.url, stream.bestURL)
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(stream.qualities), stream.bestQuality)
    }

    func testKodikVariantsNormalizeKeysAndDropGarbage() {
        // Ключи с «p» и без — одно качество; при дубле остаётся ключ, первый по алфавиту.
        let urlPlain = makeURL("https://cdn.example/720-plain.m3u8")
        let urlSuffixed = makeURL("https://cdn.example/720-suffixed.m3u8")
        let urlAuto = makeURL("https://cdn.example/auto.m3u8")
        let variants = KodikDirectResolver.variants(from: [
            "720": urlPlain,
            "720p": urlSuffixed,
            "auto": urlAuto,
            "bad": urlAuto
        ])

        XCTAssertEqual(labels(variants), ["720p"])
        XCTAssertEqual(variants.first?.url, urlPlain, "дубль качества схлопывается")
        XCTAssertTrue(KodikDirectResolver.variants(from: [:]).isEmpty)
    }

    func testKodikVariantsPreferKnownLadderOverUnknown() {
        // 1440 вне лестницы: `pickBestQuality` выбирает 1080, и первым вариантом тоже
        // должен быть 1080 — иначе меню начнётся не с того URL, что играет плеер.
        let url1080 = makeURL("https://cdn.example/1080.m3u8")
        let url1440 = makeURL("https://cdn.example/1440.m3u8")
        let qualities: [String: URL] = ["1440": url1440, "1080": url1080]

        let variants = KodikDirectResolver.variants(from: qualities)

        XCTAssertEqual(labels(variants), ["1080p", "1440p"])
        XCTAssertEqual(variants.first?.url, url1080)
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(qualities), "1080")
    }

    // MARK: - 2. AnixPlayer (StudioMir): приоритет качества

    func testAnixPlayerVariantsPriorityAndEmptyQualitySkipping() {
        let variants = AnixPlayerResolver.variants(from: [
            ("2160p", ""),
            ("1080p", "https://studiomir.example/1080.m3u8"),
            ("720p", "  https://studiomir.example/720.m3u8  "),
            ("480p", nil)
        ])

        // Пустые строки (как в живом `hls`) — не качество, в меню не попадают.
        XCTAssertEqual(labels(variants), ["1080p", "720p"])
        XCTAssertEqual(variants.first?.url.absoluteString, "https://studiomir.example/1080.m3u8")
    }

    func testAnixPlayerVariantsSkipInvalidURLs() {
        let variants = AnixPlayerResolver.variants(from: [
            ("1080p", "not a url"),
            ("720p", "data:text/plain,no"),
            ("480p", "ftp://studiomir.example/480.m3u8"),
            ("360p", "")
        ])
        XCTAssertTrue(variants.isEmpty)
    }

    func testAnixPlayerVariantsNormalizeLabel() {
        let variants = AnixPlayerResolver.variants(from: [
            ("1080", "https://studiomir.example/1080.m3u8")
        ])
        XCTAssertEqual(labels(variants), ["1080p"])
    }

    // MARK: - 3. AniLibria: варианты из JSON API и Playerjs

    func testAniLibriaVariantsFromLiveJSON() {
        // Живой формат релиза 1243: 1080 нет вовсе (`null`), 480 и 720 есть.
        let json = """
        {"episodes":[{"ordinal":1,
          "hls_480":"https://cache-rfn.libria.fun/480.m3u8?countryIso=RU",
          "hls_720":"https://cache-rfn.libria.fun/720.m3u8?countryIso=RU",
          "hls_1080":null}]}
        """
        let variants = AniLibriaResolver.variants(fromReleaseJSON: Data(json.utf8), episode: 1)

        XCTAssertEqual(labels(variants), ["720p", "480p"])
        // Прежний контракт `hlsURL` остался: лучшее качество.
        XCTAssertEqual(
            AniLibriaResolver.hlsURL(fromReleaseJSON: Data(json.utf8), episode: 1)?.absoluteString,
            "https://cache-rfn.libria.fun/720.m3u8?countryIso=RU"
        )
    }

    func testAniLibriaVariantsSkipEmptyAndMissingEpisode() {
        let json = """
        {"episodes":[{"ordinal":2,"hls_1080":"","hls_720":"https://lib.example/720.m3u8"}]}
        """
        let data = Data(json.utf8)

        XCTAssertEqual(labels(AniLibriaResolver.variants(fromReleaseJSON: data, episode: 2)), ["720p"])
        XCTAssertTrue(AniLibriaResolver.variants(fromReleaseJSON: data, episode: 9).isEmpty)
        XCTAssertTrue(AniLibriaResolver.variants(fromReleaseJSON: Data("{}".utf8), episode: 1).isEmpty)
    }

    func testAniLibriaVariantsFromPlayerjs() {
        let html = #"new Playerjs({id:"anilibriaPlayer", file:[{"id":"s1","file":"[480p]https://a.example/480.m3u8,[720p]https://a.example/720.m3u8"}]})"#

        XCTAssertEqual(
            labels(AniLibriaResolver.variants(fromPlayerjsHTML: html, episode: 1)),
            ["720p", "480p"]
        )
        XCTAssertEqual(
            AniLibriaResolver.hlsURL(fromPlayerjsHTML: html, episode: 1)?.absoluteString,
            "https://a.example/720.m3u8"
        )

        // Одна ссылка без подписи качества — запасной вариант «auto».
        let plain = #"new Playerjs({id:"p", file:[{"id":"s1","file":"https://a.example/only.m3u8"}]})"#
        XCTAssertEqual(labels(AniLibriaResolver.variants(fromPlayerjsHTML: plain, episode: 1)), ["auto"])
    }

    // MARK: - 4. RuTube: разбор master.m3u8

    /// Живой master-плейлист 24.11.2026 (сокращён): по два зеркала на качество.
    private let masterPlaylist = """
    #EXTM3U
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=187000,FRAME-RATE=23.976,RESOLUTION=256x144
    https://salam-tmn-mset-92.rtbcdn.ru/144-a.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=187000,FRAME-RATE=23.976,RESOLUTION=256x144
    https://river-1.rutube.ru/144-b.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1261000,FRAME-RATE=23.976,RESOLUTION=1280x720
    https://salam-tmn-mset-92.rtbcdn.ru/720-a.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=2578000,FRAME-RATE=23.976,RESOLUTION=1920x1080
    https://salam-tmn-mset-92.rtbcdn.ru/1080-a.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=2578000,FRAME-RATE=23.976,RESOLUTION=1920x1080
    https://river-1.rutube.ru/1080-b.m3u8
    """

    func testRutubeMasterPlaylistVariants() {
        let base = makeURL("https://bl.rutube.ru/route/c62caf58bd71d1641e88cdc97d6bc6b9.m3u8")
        let variants = RutubeResolver.qualityVariants(from: masterPlaylist, baseURL: base)

        // Лучшее первым; зеркала одного разрешения схлопнуты в один пункт меню.
        XCTAssertEqual(labels(variants), ["1080p", "720p", "144p"])
        XCTAssertTrue(variants.first?.url.absoluteString.contains("/1080-") == true)
        XCTAssertNotNil(variants.first)
    }

    func testRutubeMasterPlaylistRelativeURLs() {
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1261000,RESOLUTION=1280x720
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2578000,RESOLUTION=1920x1080
        /vod/1080/index.m3u8
        """
        let base = makeURL("https://bl.rutube.ru/route/c62caf58bd71d1641e88cdc97d6bc6b9.m3u8")
        let variants = RutubeResolver.qualityVariants(from: playlist, baseURL: base)

        XCTAssertEqual(labels(variants), ["1080p", "720p"])
        XCTAssertEqual(variants.first?.url.absoluteString, "https://bl.rutube.ru/vod/1080/index.m3u8")
        XCTAssertEqual(variants.last?.url.absoluteString, "https://bl.rutube.ru/route/720/index.m3u8")
    }

    func testRutubeMasterPlaylistKeepsHigherBandwidthMirror() {
        // Одинаковое разрешение (значит, и подпись) — остаётся зеркало с большим BANDWIDTH.
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720
        https://slow.example/720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        https://fast.example/720.m3u8
        """
        let base = makeURL("https://bl.rutube.ru/master.m3u8")
        let variants = RutubeResolver.qualityVariants(from: playlist, baseURL: base)

        XCTAssertEqual(labels(variants), ["720p"])
        XCTAssertEqual(variants.first?.url.absoluteString, "https://fast.example/720.m3u8")
    }

    func testRutubeMasterPlaylistGarbageReturnsEmpty() {
        let base = makeURL("https://bl.rutube.ru/master.m3u8")

        // Медиа-плейлист: тегов `#EXT-X-STREAM-INF` нет — качеств не предлагаем.
        XCTAssertTrue(RutubeResolver.qualityVariants(
            from: "#EXTM3U\n#EXTINF:10,\nseg-1.ts\n#EXT-X-ENDLIST",
            baseURL: base
        ).isEmpty)
        XCTAssertTrue(RutubeResolver.qualityVariants(from: "", baseURL: base).isEmpty)
        XCTAssertTrue(RutubeResolver.qualityVariants(from: "not a playlist", baseURL: base).isEmpty)
    }

    func testRutubeQualityLabels() {
        // Та же лестница, что у `VideoQualitySelector`/Android-парсера RuTube.
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 1920, height: 1080), "1080p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 1280, height: 720), "720p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 3840, height: 2160), "2160p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 2560, height: 1440), "1440p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 854, height: 480), "480p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 640, height: 360), "360p")
        // Нестандартные разрешения — ближайшая нижняя ступень (как у VideoQualitySelector),
        // совсем маленькие — по высоте.
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 848, height: 476), "360p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 426, height: 240), "240p")
        XCTAssertEqual(RutubeResolver.qualityLabel(width: 256, height: 144), "144p")
    }
}
