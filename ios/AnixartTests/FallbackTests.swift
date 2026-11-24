import XCTest
import Foundation
@testable import Anixart

/// Автоподбор источника и preflight HTML-плеера: чистые функции
/// `SourceFallbackService`, разворачивание прокси-ссылки Anixart, подсказки
/// причин отказа и проверка `probe` для не-HTML целей.
///
/// Все тесты локальные: сеть не используется. `looksLikeProviderError` и
/// `candidateOrder` — `nonisolated static`, поэтому вызываются синхронно;
/// `effectiveWebTarget` и `probe` требуют экземпляр `@MainActor`-сервиса,
/// поэтому тесты `async` и обращаются к главному актору через `await`.
final class FallbackTests: XCTestCase {

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    /// `effectiveWebTarget` объявлен `nonisolated`, но сам сервис — `@MainActor`,
    /// поэтому достаём его экземпляр и вызываем метод на главном акторе.
    private func effectiveWebTarget(_ target: PlaybackTarget) async -> PlaybackTarget {
        await MainActor.run {
            SourceFallbackService.shared.effectiveWebTarget(target)
        }
    }

    private func makeTarget(kind: PlaybackKind,
                            title: String = "1 серия",
                            providerName: String = "Источник",
                            referer: URL? = nil) -> PlaybackTarget {
        PlaybackTarget(kind: kind, title: title, providerName: providerName, referer: referer)
    }

    // MARK: - 1. Страница ошибки провайдера

    func testLooksLikeProviderError() {
        // Любой HTTP-статус >= 400 — уже ошибка, тело даже не нужно.
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(status: 500, body: ""))
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(status: 404, body: ""))
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(
            status: 500, body: "<html><body><video src=\"x\"></video></body></html>"),
            "статус важнее содержимого")

        // HTTP 200, но в теле — заглушка провайдера.
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(
            status: 200, body: "<html><body>Error code: ds</body></html>"))
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(
            status: 200, body: "<html><body>Извините, но данной странице не существует</body></html>"),
            "404-страница прокси приходит с кодом 200")
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(
            status: 200, body: "Данный источник не поддерживается"),
            "провайдер жив, но источник не поддержан")

        // Регистр маркера не важен.
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(
            status: 200, body: "ERROR CODE: ds"))
        XCTAssertTrue(SourceFallbackService.looksLikeProviderError(
            status: 200, body: "<b>НЕ ПОДДЕРЖИВАЕТСЯ</b>"))

        // Настоящая страница плеера и пустой ответ ошибкой не считаются.
        XCTAssertFalse(SourceFallbackService.looksLikeProviderError(
            status: 200, body: "<html><body><video src=\"https://cdn.example/1.m3u8\"></video></body></html>"))
        XCTAssertFalse(SourceFallbackService.looksLikeProviderError(status: 200, body: ""))
        XCTAssertFalse(SourceFallbackService.looksLikeProviderError(status: 204, body: ""),
                       "успешный статус без тела — не ошибка")
    }

    // MARK: - 2. Порядок кандидатов

    func testCandidateOrder() {
        let sources = (1...6).map {
            EpisodeSource(id: $0,
                          name: "Озвучка \($0)",
                          type: nil,
                          episodesCount: 12,
                          quality: 720)
        }

        // Не сработавший источник исключён, порядок сервера сохранён, не больше 4.
        let ordered = SourceFallbackService.candidateOrder(sources: sources, excluding: 2, limit: 4)
        XCTAssertEqual(ordered.count, 4, "лимит кандидатов — 4 штуки")
        XCTAssertEqual(ordered.map(\.id), [1, 3, 4, 5], "порядок сервера сохраняется, id 2 выброшен")
        XCTAssertFalse(ordered.contains { $0.id == 2 }, "отказавший источник повторно не предлагаем")

        // Исключённого нет в списке — работает только лимит.
        let missingExclusion = SourceFallbackService.candidateOrder(sources: sources, excluding: 99, limit: 4)
        XCTAssertEqual(missingExclusion.map(\.id), [1, 2, 3, 4])

        // Пустой список не даёт кандидатов.
        XCTAssertTrue(SourceFallbackService.candidateOrder(sources: [], excluding: 1, limit: 4).isEmpty)

        // Неположительный лимит — пустой список (защита от 0 и отрицательных).
        XCTAssertTrue(SourceFallbackService.candidateOrder(sources: sources, excluding: 1, limit: 0).isEmpty)

        // Если после исключения осталось меньше лимита — отдаём сколько есть.
        XCTAssertEqual(SourceFallbackService.candidateOrder(sources: sources, excluding: 2, limit: 10).map(\.id),
                       [1, 3, 4, 5, 6])
    }

    // MARK: - 3. Прокси anixmirai разворачивается до исходного плеера

    func testEffectiveWebTargetUnwrapsProxy() async throws {
        let originalURL = makeURL("https://kodikplayer.com/seria/1/abc/720p?d=1")
        let proxyURL = makeURL("https://anixmirai.com/iframe?url=https%3A%2F%2Fkodikplayer.com%2Fseria%2F1%2Fabc%2F720p%3Fd%3D1")
        let proxied = makeTarget(kind: .web(proxyURL),
                                 providerName: "Kodik",
                                 referer: PlaybackResolver.anixmiraiReferer)

        let effective = await effectiveWebTarget(proxied)

        // Проверяем исходную страницу плеера, а не всегда-успешную прокси-страницу.
        XCTAssertEqual(effective.kind, .web(originalURL))
        XCTAssertEqual(effective.title, proxied.title, "заголовок сохраняется")
        XCTAssertEqual(effective.providerName, "Kodik", "имя провайдера сохраняется")
        XCTAssertEqual(effective.referer, PlaybackResolver.anixmiraiReferer,
                       "Referer прокси сохраняется")

        // Обычная web-ссылка не через anixmirai не меняется.
        let sibnetURL = makeURL("https://video.sibnet.ru/shell.php?videoid=123")
        let plain = makeTarget(kind: .web(sibnetURL), providerName: "Sibnet")
        let plainEffective = await effectiveWebTarget(plain)
        XCTAssertEqual(plainEffective.kind, .web(sibnetURL))
        XCTAssertEqual(plainEffective, plain)

        // Прямой HLS-поток не трогаем.
        let hlsURL = makeURL("https://example.invalid/serie/1/720p.m3u8")
        let hls = makeTarget(kind: .hls(hlsURL), providerName: "AnixPlayer")
        let hlsEffective = await effectiveWebTarget(hls)
        XCTAssertEqual(hlsEffective.kind, .hls(hlsURL))
        XCTAssertEqual(hlsEffective, hls)
    }

    // MARK: - 4. Подсказки причин отказа

    func testReasonHints() {
        let reasons: [PlaybackFallbackReason] = [
            .emptyURL,
            .providerHTTP(500),
            .providerHTTP(404),
            .resolutionFailed("Резолвер не получил m3u8"),
            .unsupported("Kodik")
        ]

        for reason in reasons {
            XCTAssertFalse(reason.userHint.isEmpty, "у причины \(reason) пустая подсказка для пользователя")
        }

        // HTTP-код и имя плеера подставляются, текст резолвера уходит как есть.
        XCTAssertEqual(PlaybackFallbackReason.emptyURL.userHint, "Сервер не вернул ссылку")
        XCTAssertTrue(PlaybackFallbackReason.providerHTTP(502).userHint.contains("502"),
                      "код ошибки должен попасть в подсказку: \(PlaybackFallbackReason.providerHTTP(502).userHint)")
        XCTAssertTrue(PlaybackFallbackReason.unsupported("AniLibria").userHint.contains("AniLibria"),
                      "имя плеера должно попасть в подсказку: \(PlaybackFallbackReason.unsupported("AniLibria").userHint)")
        XCTAssertEqual(PlaybackFallbackReason.resolutionFailed("таймаут резолвера").userHint,
                       "таймаут резолвера")
        XCTAssertNotEqual(PlaybackFallbackReason.emptyURL.userHint,
                          PlaybackFallbackReason.unsupported("Kodik").userHint,
                          "пустая ссылка и неподдержанный плеер — разные причины")
    }

    // MARK: - 5. probe для HLS и YouTube — без сети

    func testProbeForHLSAndYouTubeIsTrue() async throws {
        // example.invalid гарантирует: если бы запрос всё-таки пошёл, тест это заметил.
        let hls = makeTarget(kind: .hls(makeURL("https://example.invalid/serie/1/720p.m3u8")),
                             providerName: "AnixPlayer")
        let hlsOK = await SourceFallbackService.shared.probe(hls)
        XCTAssertTrue(hlsOK, "прямому потоку preflight-запрос не нужен")

        let youtube = makeTarget(kind: .youtube(videoId: "dQw4w9WgXcQ"),
                                 providerName: "YouTube",
                                 referer: PlaybackResolver.youtubeReferer)
        let youtubeOK = await SourceFallbackService.shared.probe(youtube)
        XCTAssertTrue(youtubeOK, "YouTube-встраивание проверяет AVPlayer/WKWebView, а не сервис")
    }
}
