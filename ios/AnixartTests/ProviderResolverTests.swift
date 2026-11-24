import XCTest
import Foundation
@testable import Anixart

/// Чистые парсеры провайдеров и выбора качества — без сети.
///
/// Каждый тест подаёт синтетический вход (ссылку, JSON, HTML, master-плейлист)
/// в метод, который в приложении разбирает ответ сервера, и проверяет результат.
/// Сетевые `resolve(...)`-методы здесь не вызываются.
final class ProviderResolverTests: XCTestCase {

    // MARK: - Вспомогательные

    /// Ключ сохранённого качества (`VideoQualitySelector.qualityDefaultsKey`).
    private let qualityKey = VideoQualitySelector.qualityDefaultsKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: qualityKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: qualityKey)
        super.tearDown()
    }

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    // MARK: - 1. RuTube: id видео из ссылки

    func testRutubeVideoId() {
        // 32-hex id собираем из повторяющейся пары, чтобы не считать символы руками.
        let videoId = String(repeating: "0123456789abcdef", count: 2)

        // Четыре шаблона Android-парсера: video, play/embed, shorts, video/private.
        let links = [
            "https://rutube.ru/video/\(videoId)/",
            "https://rutube.ru/video/\(videoId)",
            "https://rutube.ru/play/embed/\(videoId)",
            "https://rutube.ru/shorts/\(videoId)",
            "https://rutube.ru/video/private/\(videoId)?p=privatekey",
            "https://www.rutube.ru/video/\(videoId)/"
        ]
        for link in links {
            XCTAssertEqual(RutubeResolver.videoId(from: makeURL(link)), videoId,
                           "не извлекли id RuTube из \(link)")
        }

        // Отрицательные случаи: чужой хост, короткий id, id не из hex, ссылка без id.
        XCTAssertNil(RutubeResolver.videoId(from: makeURL("https://example.com/video/\(videoId)")))
        XCTAssertNil(RutubeResolver.videoId(from: makeURL("https://rutube.ru/video/abc123")))
        XCTAssertNil(RutubeResolver.videoId(
            from: makeURL("https://rutube.ru/video/\(String(repeating: "z", count: 32))")
        ))
        XCTAssertNil(RutubeResolver.videoId(from: makeURL("https://rutube.ru/")))
    }

    // MARK: - 2. AniLibria: id релиза и серия из подписанной ссылки

    func testAniLibriaReference() {
        let signed = makeURL(
            "https://anixart.libria.fun/public/iframe.php?id=1243&ep=2&d=2026112405&s=abc123&ip=1.2.3.4"
        )
        let reference = AniLibriaResolver.reference(from: signed)
        XCTAssertEqual(reference?.releaseId, 1243, "id релиза из query id")
        XCTAssertEqual(reference?.episode, 2, "номер серии из query ep")

        // Без одного из обязательных параметров разбора нет.
        XCTAssertNil(AniLibriaResolver.reference(
            from: makeURL("https://anixart.libria.fun/public/iframe.php?ep=2&d=2026112405")
        ))
        XCTAssertNil(AniLibriaResolver.reference(
            from: makeURL("https://anixart.libria.fun/public/iframe.php?id=1243&d=2026112405")
        ))
        // Нечисловой id тоже не разбирается.
        XCTAssertNil(AniLibriaResolver.reference(
            from: makeURL("https://anixart.libria.fun/public/iframe.php?id=abc&ep=2")
        ))
    }

    // MARK: - 3. AniLibria: HLS из JSON релиза

    /// Живой формат `anime/releases/{id}`: `episodes[]` с `ordinal` и полями `hls_*`.
    private let releaseJSON = """
    {"episodes":[{"ordinal":2,"hls_480":"https://x/480.m3u8","hls_720":"https://x/720.m3u8","hls_1080":""},{"ordinal":3,"hls_1080":"https://x/1080.m3u8"}]}
    """

    func testAniLibriaJSON() {
        let data = Data(releaseJSON.utf8)

        // У серии 2 пустой hls_1080 — берётся лучшее непустое качество, 720.
        XCTAssertEqual(AniLibriaResolver.hlsURL(fromReleaseJSON: data, episode: 2)?.absoluteString,
                       "https://x/720.m3u8")
        // У серии 3 есть только 1080 — он и выбирается.
        XCTAssertEqual(AniLibriaResolver.hlsURL(fromReleaseJSON: data, episode: 3)?.absoluteString,
                       "https://x/1080.m3u8")
        // Серии 9 в ответе нет.
        XCTAssertNil(AniLibriaResolver.hlsURL(fromReleaseJSON: data, episode: 9))
        // Ответ без episodes не роняет разбор.
        XCTAssertNil(AniLibriaResolver.hlsURL(fromReleaseJSON: Data("{}".utf8), episode: 1))
    }

    // MARK: - 4. AniLibria: фолбэк Playerjs из HTML

    func testAniLibriaPlayerjs() {
        let html = #"new Playerjs({id:"anilibriaPlayer", file:[{"id":"s1","file":"[480p]https://a/480.m3u8,[720p]https://a/720.m3u8"}]})"#
        XCTAssertEqual(AniLibriaResolver.hlsURL(fromPlayerjsHTML: html, episode: 1)?.absoluteString,
                       "https://a/720.m3u8", "из списка качеств Playerjs берётся лучшее")

        // Страница без Playerjs — HLS-ссылки нет.
        XCTAssertNil(AniLibriaResolver.hlsURL(fromPlayerjsHTML: #"<html><body>no player</body></html>"#,
                                             episode: 1))
    }

    // MARK: - 5. AnixPlayer (StudioMir): id аниме из ссылки

    func testAnixPlayerAniId() {
        let embed = makeURL("https://api.studiomir.club/tsmplayer/embed?ani=53&plf=anixart&ep=1")
        XCTAssertEqual(AnixPlayerResolver.aniId(from: embed), "53")

        // Синоним параметра и запасной формат — id в пути страницы аниме.
        XCTAssertEqual(AnixPlayerResolver.aniId(
            from: makeURL("https://api.studiomir.club/tsmplayer/embed?anime_id=53")
        ), "53")
        XCTAssertEqual(AnixPlayerResolver.aniId(from: makeURL("https://studiomir.club/anime/53-kanojo")),
                       "53")

        // Нечисловой ani и ссылка без ani идентификатора не дают.
        XCTAssertNil(AnixPlayerResolver.aniId(
            from: makeURL("https://api.studiomir.club/tsmplayer/embed?ani=abc&plf=anixart&ep=1")
        ))
        XCTAssertNil(AnixPlayerResolver.aniId(
            from: makeURL("https://api.studiomir.club/tsmplayer/embed?plf=anixart&ep=1")
        ))
    }

    // MARK: - 6. Выбор качества: разбор master-плейлиста

    func testQualityPlaylistParsing() {
        let masterURL = makeURL("https://cdn.example.com/hls/master.m3u8")
        let master = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=854x480
        480/index.m3u8
        """

        let variants = VideoQualitySelector.parse(playlist: master, baseURL: masterURL)

        XCTAssertEqual(variants.count, 3, "три качества из трёх #EXT-X-STREAM-INF")
        XCTAssertEqual(variants.map(\.label), ["1080p", "720p", "480p"], "сверху — лучшее качество")
        XCTAssertEqual(variants.map(\.id), ["1080p", "720p", "480p"], "id варианта совпадает с меткой")
        XCTAssertEqual(variants.map { $0.bandwidth ?? 0 }, [5_000_000, 2_800_000, 1_400_000])

        // Ссылки в master-плейлисте относительные — резолвятся от его URL.
        XCTAssertEqual(variants.map(\.url.absoluteString), [
            "https://cdn.example.com/hls/1080/index.m3u8",
            "https://cdn.example.com/hls/720/index.m3u8",
            "https://cdn.example.com/hls/480/index.m3u8"
        ])

        // Медиа-плейлист (нет #EXT-X-STREAM-INF) — один вариант auto с исходной ссылкой.
        let mediaURL = makeURL("https://cdn.example.com/hls/720/index.m3u8")
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:10.0,
        seg0.ts
        #EXTINF:10.0,
        seg1.ts
        #EXT-X-ENDLIST
        """

        let auto = VideoQualitySelector.parse(playlist: media, baseURL: mediaURL)
        XCTAssertEqual(auto.count, 1, "у медиа-плейлиста список качеств не строится")
        XCTAssertEqual(auto.first?.id, "auto")
        XCTAssertEqual(auto.first?.label, "auto")
        XCTAssertEqual(auto.first?.url.absoluteString, mediaURL.absoluteString)
    }

    // MARK: - 7. Выбор качества: запоминание и подстановка

    func testQualityRemember() {
        let variants = [
            VideoQualityVariant(id: "1080p", label: "1080p",
                                url: makeURL("https://cdn.example.com/hls/1080/index.m3u8"),
                                bandwidth: 5_000_000),
            VideoQualityVariant(id: "720p", label: "720p",
                                url: makeURL("https://cdn.example.com/hls/720/index.m3u8"),
                                bandwidth: 2_800_000),
            VideoQualityVariant(id: "480p", label: "480p",
                                url: makeURL("https://cdn.example.com/hls/480/index.m3u8"),
                                bandwidth: 1_400_000)
        ]

        // Выбор ещё не сохраняли — плеер играет по умолчанию.
        XCTAssertNil(VideoQualitySelector.rememberedLabel())
        XCTAssertNil(VideoQualitySelector.preferred(in: variants))

        VideoQualitySelector.remember(variants[1])

        // В UserDefaults лежит только метка: подписанные ссылки истекают.
        XCTAssertEqual(UserDefaults.standard.string(forKey: qualityKey), "720p")
        XCTAssertEqual(VideoQualitySelector.rememberedLabel(), "720p")
        XCTAssertEqual(VideoQualitySelector.preferred(in: variants)?.label, "720p")
        XCTAssertEqual(VideoQualitySelector.preferred(in: variants)?.url.absoluteString,
                       variants[1].url.absoluteString)

        // Сохранённого качества нет в новом плейлисте — nil, играет по умолчанию.
        XCTAssertNil(VideoQualitySelector.preferred(in: [variants[0], variants[2]]))
    }

    // MARK: - 8. Sibnet: только компилируемость

    /// Чистых парсеров у Sibnet нет: `videoPath`/`absoluteURL`/`removingDefaultPort`
    /// объявлены `private`, а `resolve(...)` требует сети. Поэтому тест проверяет
    /// лишь то, что тип и его константы доступны тестовому таргету.
    func testSibnetResolverSurface() {
        XCTAssertEqual(SibnetResolver.providerName, "Sibnet")
        XCTAssertEqual(SibnetResolver.referer?.host, "video.sibnet.ru")
        XCTAssertFalse(SibnetResolver.mobileSafariUserAgent.isEmpty)
        XCTAssertFalse(SibnetResolver.androidWebViewUserAgent.isEmpty)
    }
}
