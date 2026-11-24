import XCTest
import Foundation
@testable import Anixart

/// Прямой резолв Kodik (`KodikDirectResolver`): нормализация подписанной ссылки,
/// разбор пути, декод `src` из `ftor` и выбор качества.
///
/// Сеть в тестах не нужна: проверяется чистая логика на реальных строках, снятых
/// с живого API 24.11.2026 (`GET kodikplayer.com/ftor` → `200 application/json`).
final class KodikDirectTests: XCTestCase {

    // MARK: - Живые данные пробы 24.11.2026

    /// Подписанная ссылка из `episode/target/1/8/1` (фикстура `episode_target.json`).
    private let signedLink = "https://kodikplayer.com/seria/175268/"
        + "48eeb2a7bd81c9c3139634faa2b793db/720p"
        + "?d=2026112407&s=zd47amJVOWWQKd8DTmFvL0zPCMDOHG1MSRlzc1JT1G2WT7eyon0BUmbGXa4tfGIq"
        + "&ip=178.208.227.243"

    /// Та же ссылка после нормализации (query отброшен) — она же Referer к `ftor`.
    private let normalizedLink = "https://kodikplayer.com/seria/175268/"
        + "48eeb2a7bd81c9c3139634faa2b793db/720p"

    /// Реальные `src` из ответа `ftor` — 360, 480 и 720.
    private let liveSource360 = "Tg9rjO91HLQck29aj2ZrHO4cG29bT3DhHFR1kOfdGEZhThM3UOCgUuU4TBCeGuU"
        + "bVODpUA1pUuQ5TBY2VrM2HEU3WBM2VA9sU2HtGBCeUBHsGrQ3VLk4UBIfHuQ0HuCgGrk2HOZuVhwgULQ2UBMgVL"
        + "M1ThU2UK5bkLY6iOfhWu1pjutuHFV0Tu0hlBo"
    private let liveSource480 = "Tg9rjO91HLQck29aj2ZrHO4cG29bT3DhHFR1kOfdGEZhThM3UOCgUuU4TBCeGuU"
        + "bVODpUA1pUuQ5TBY2VrM2HEU3WBM2VA9sU2HtGBCeUBHsGrQ3VLk4UBIfHuQ0HuCgGrk2HOZuVhwgULQ2UBMgVL"
        + "M1ThY4UK5bkLY6iOfhWu1pjutuHFV0Tu0hlBo"
    private let liveSource720 = "Tg9rjO91HLQck29aj2ZrHO4cG29bT3DhHFR1kOfdGEZhThM3UOCgUuU4TBCeGuU"
        + "bVODpUA1pUuQ5TBY2VrM2HEU3WBM2VA9sU2HtGBCeUBHsGrQ3VLk4UBIfHuQ0HuCgGrk2HOZuVhwgULQ2UBMgVL"
        + "M1ThkgUK5bkLY6iOfhWu1pjutuHFV0Tu0hlBo"

    /// Ожидаемые результаты декода: протокол-относительные ссылки на CDN Kodik.
    private let liveURL360 = "//cloud2.solodcdn.com/useruploads/"
        + "170e22c8-50bc-4ea1-a2b9-46616ec79165/"
        + "d3fea5016db27478101fb4fe2b76ddf7:2026112415/360.mp4:hls:manifest.m3u8"
    private let liveURL480 = "//cloud2.solodcdn.com/useruploads/"
        + "170e22c8-50bc-4ea1-a2b9-46616ec79165/"
        + "d3fea5016db27478101fb4fe2b76ddf7:2026112415/480.mp4:hls:manifest.m3u8"
    private let liveURL720 = "//cloud2.solodcdn.com/useruploads/"
        + "170e22c8-50bc-4ea1-a2b9-46616ec79165/"
        + "d3fea5016db27478101fb4fe2b76ddf7:2026112415/720.mp4:hls:manifest.m3u8"

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    // MARK: - 1. Декод `src` из ftor

    func testDecodesLiveSources() {
        XCTAssertEqual(KodikDirectResolver.decodeSource(liveSource360), liveURL360)
        XCTAssertEqual(KodikDirectResolver.decodeSource(liveSource480), liveURL480)
        XCTAssertEqual(KodikDirectResolver.decodeSource(liveSource720), liveURL720)

        // Проверенный живой префикс: 720-й ссылкой подтверждён весь путь ROT+18 → Base64.
        XCTAssertTrue(liveURL720.hasPrefix("//cloud2.solodcdn.com/"))
        XCTAssertTrue(KodikDirectResolver.decodeSource(liveSource720)?.hasPrefix("//cloud2.solodcdn.com/") == true,
                      "декод не должен возвращать закодированную строку как есть")
    }

    func testDecodesToPlayableHLSURL() throws {
        let url = try XCTUnwrap(KodikDirectResolver.preferPlayableURL(liveSource720))

        XCTAssertEqual(url.absoluteString, "https:" + liveURL720)
        XCTAssertEqual(url.host, "cloud2.solodcdn.com")
        XCTAssertEqual(url.pathExtension, "m3u8", "манифест Kodik должен остаться HLS")
        XCTAssertTrue(url.absoluteString.hasSuffix("/720.mp4:hls:manifest.m3u8"))
    }

    func testDecodeSourcePassesThroughReadyURLs() {
        // Готовый абсолютный URL — без изменений.
        XCTAssertEqual(KodikDirectResolver.decodeSource("https://cloud1.solodcdn.com/x/720.mp4"),
                       "https://cloud1.solodcdn.com/x/720.mp4")
        // Протокол-относительный — добавляется https.
        XCTAssertEqual(KodikDirectResolver.decodeSource(liveURL720), "https:" + liveURL720)
        // URL на CDN Kodik без схемы — считается готовым (схему добавит preferPlayableURL).
        XCTAssertEqual(KodikDirectResolver.decodeSource("cloud2.solodcdn.com/useruploads/x/720.mp4"),
                       "cloud2.solodcdn.com/useruploads/x/720.mp4")
    }

    // MARK: - 2. Нормализация подписанной ссылки

    func testNormalizesEmbedURLDropsQuery() throws {
        let normalized = try XCTUnwrap(KodikDirectResolver.normalizedEmbedURL(makeURL(signedLink)))

        XCTAssertEqual(normalized.absoluteString, normalizedLink, "query d/s/ip для ftor не нужен")
        XCTAssertNil(URLComponents(url: normalized, resolvingAgainstBaseURL: false)?.query)
        XCTAssertNil(URLComponents(url: normalized, resolvingAgainstBaseURL: false)?.fragment)
    }

    func testNormalizesWebProxyTarget() throws {
        // В `PlaybackKind.web` Kodik приходит уже обёрнутым в прокси Anixart —
        // нормализация должна развернуть его в исходную страницу Kodik.
        let proxied = try XCTUnwrap(PlaybackResolver.proxied(makeURL(signedLink)))
        let normalized = try XCTUnwrap(KodikDirectResolver.normalizedEmbedURL(proxied))

        XCTAssertEqual(normalized.absoluteString, normalizedLink)
    }

    // MARK: - 3. Разбор пути

    func testParsesIdentityForSeria() throws {
        let identity = try XCTUnwrap(KodikDirectResolver.parseIdentity(makeURL(signedLink)))

        XCTAssertEqual(identity.type, "seria")
        XCTAssertEqual(identity.id, "175268")
        XCTAssertEqual(identity.hash, "48eeb2a7bd81c9c3139634faa2b793db")
    }

    func testParsesIdentityForOtherTypesAndBareQuality() throws {
        let video = try XCTUnwrap(KodikDirectResolver.parseIdentity(
            makeURL("https://kodikplayer.com/video/12345/abcdef0123456789abcdef0123456789/720")
        ))
        XCTAssertEqual(video.type, "video")
        XCTAssertEqual(video.id, "12345")
        XCTAssertEqual(video.hash, "abcdef0123456789abcdef0123456789")

        let movie = try XCTUnwrap(KodikDirectResolver.parseIdentity(
            makeURL("https://kodikplayer.com/movie/777/0123456789abcdef0123456789abcdef/1080p")
        ))
        XCTAssertEqual(movie.type, "movie")

        let anime = try XCTUnwrap(KodikDirectResolver.parseIdentity(
            makeURL("https://kodikplayer.com/anime/42/0123456789abcdef0123456789abcdef/480/")
        ))
        XCTAssertEqual(anime.type, "anime", "хвостовой слэш не мешает разбору")
    }

    // MARK: - 4. mp4 → HLS и другие ссылки

    func testPreferPlayableURLConvertsProgressiveMP4ToHLS() throws {
        let progressive = "https://cloud1.solodcdn.com/useruploads/abc/720.mp4"
        let url = try XCTUnwrap(KodikDirectResolver.preferPlayableURL(progressive))

        XCTAssertEqual(url.absoluteString, progressive + ":hls:manifest.m3u8")
        XCTAssertEqual(url.pathExtension, "m3u8")
    }

    func testPreferPlayableURLConvertsEveryKodikCDN() throws {
        let cdns = [
            "https://get.kodik-storage.com/useruploads/x/480.mp4",
            "https://cdn.zerocdn.com/useruploads/x/360.mp4",
            "https://edge.animedia.tv/useruploads/x/1080.mp4",
            "https://cloud.kodik-cdn.com/useruploads/x/720.mp4"
        ]
        for cdn in cdns {
            let url = try XCTUnwrap(KodikDirectResolver.preferPlayableURL(cdn), "не разобрали \(cdn)")
            XCTAssertTrue(url.absoluteString.hasSuffix(":hls:manifest.m3u8"), "cdn: \(cdn)")
        }
    }

    func testPreferPlayableURLKeepsForeignAndAlreadyHLS() throws {
        // Прогрессивный mp4 чужого хоста — оставляем как есть: AVPlayer его проиграет.
        let foreign = "https://example.com/video/720.mp4"
        XCTAssertEqual(KodikDirectResolver.preferPlayableURL(foreign)?.absoluteString, foreign)

        // Готовый HLS не трогаем.
        let hls = "https://cdn.example.com/stream.m3u8"
        XCTAssertEqual(KodikDirectResolver.preferPlayableURL(hls)?.absoluteString, hls)

        // Голый хост CDN: добавляем схему и HLS-суффикс.
        XCTAssertEqual(
            KodikDirectResolver.preferPlayableURL("cloud2.solodcdn.com/useruploads/x/720.mp4")?.absoluteString,
            "https://cloud2.solodcdn.com/useruploads/x/720.mp4:hls:manifest.m3u8"
        )

        // Query не теряется: суффикс вставляется до него.
        XCTAssertEqual(
            KodikDirectResolver.preferPlayableURL("https://cloud1.solodcdn.com/x/720.mp4?hash=abc")?.absoluteString,
            "https://cloud1.solodcdn.com/x/720.mp4:hls:manifest.m3u8?hash=abc"
        )
    }

    // MARK: - 5. Выбор качества

    func testPickBestQualityPreference() {
        let url = makeURL("https://example.com/stream.m3u8")

        XCTAssertEqual(KodikDirectResolver.pickBestQuality(
            ["360": url, "480": url, "720": url, "1080": url]
        ), "1080")
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(
            ["360": url, "480": url, "720": url]
        ), "720")
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(["360": url, "480": url]), "480")
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(["360": url]), "360")
        // Ключ с «p» сравнивается терпимо и возвращается как есть.
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(["480": url, "720p": url]), "720p")
        // Качество вне стандартной лестницы — берём самое высокое числовое.
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(["240": url]), "240")
        // Пустая карта и нечисловые ключи — nil.
        XCTAssertNil(KodikDirectResolver.pickBestQuality([:]))
        XCTAssertNil(KodikDirectResolver.pickBestQuality(["auto": url]))
    }

    // MARK: - 6. Терпимый разбор ответа ftor

    func testFtorJSONDecodingIsTolerant() throws {
        let json = """
        {
          "advert_script": "",
          "domain": "kodikplayer.com",
          "default": 360,
          "links": {
            "360": [{"src": "\(liveSource360)", "type": "application/x-mpegURL"}],
            "480": [{"src": "\(liveSource480)"}],
            "720": [{"src": "\(liveSource720)", "extra": {"nested": true}}],
            "1080": [],
            "bad": null,
            "auto": "oops"
          },
          "vast": []
        }
        """
        let qualities = KodikDirectResolver.qualityURLs(fromFtorJSON: Data(json.utf8))

        XCTAssertEqual(Set(qualities.keys), Set(["360", "480", "720"]),
                       "пустые и нечисловые качества отбрасываются")
        XCTAssertEqual(qualities["720"]?.absoluteString, "https:" + liveURL720)
        XCTAssertEqual(qualities["360"]?.absoluteString, "https:" + liveURL360)
        XCTAssertEqual(KodikDirectResolver.pickBestQuality(qualities), "720")
    }

    func testFtorJSONGarbageReturnsEmpty() {
        let garbage = [
            Data(),
            Data("not json".utf8),
            Data("[]".utf8),
            Data("{\"links\": null}".utf8),
            Data("{\"links\": [1, 2, 3]}".utf8),
            Data("{\"code\":0}".utf8)
        ]
        for data in garbage {
            XCTAssertTrue(KodikDirectResolver.qualityURLs(fromFtorJSON: data).isEmpty,
                          "мусор не должен давать качества: \(String(decoding: data, as: UTF8.self))")
        }
    }

    // MARK: - 7. Негативные кейсы

    func testGarbageInputsReturnNil() {
        XCTAssertNil(KodikDirectResolver.normalizedEmbedURL(makeURL("https://kodikplayer.com/")))
        XCTAssertNil(KodikDirectResolver.normalizedEmbedURL(
            makeURL("https://kodikplayer.com/seria/175268/720p")
        ), "без хеша путь не разобрать")
        XCTAssertNil(KodikDirectResolver.normalizedEmbedURL(
            makeURL("https://kodikplayer.com/unknown/1/abcdef0123456789/720p")
        ), "неизвестный тип страницы")
        XCTAssertNil(KodikDirectResolver.normalizedEmbedURL(
            makeURL("https://kodikplayer.com/seria/abc/abcdef0123456789/720p")
        ), "id должен быть числом")
        XCTAssertNil(KodikDirectResolver.normalizedEmbedURL(
            makeURL("https://kodikplayer.com/seria/175268/48eeb2a7bd81c9c3139634faa2b793db/no-quality")
        ), "качество должно быть числом")

        XCTAssertNil(KodikDirectResolver.parseIdentity(makeURL("https://kodikplayer.com/")))
        XCTAssertNil(KodikDirectResolver.parseIdentity(
            makeURL("https://kodikplayer.com/seria/175268")
        ))

        XCTAssertNil(KodikDirectResolver.decodeSource(""))
        XCTAssertNil(KodikDirectResolver.decodeSource("   "))
        XCTAssertNil(KodikDirectResolver.decodeSource("!!!not-base64!!!"))

        XCTAssertNil(KodikDirectResolver.preferPlayableURL(""))
        XCTAssertNil(KodikDirectResolver.preferPlayableURL(normalizedLink),
                     "HTML-страница Kodik — не поток")
        XCTAssertNil(KodikDirectResolver.preferPlayableURL("javascript:alert(1)"))
        XCTAssertNil(KodikDirectResolver.preferPlayableURL("data:text/plain;base64,SGVsbG8="))
    }
}
