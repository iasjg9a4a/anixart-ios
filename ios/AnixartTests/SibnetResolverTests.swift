import XCTest
import Foundation
@testable import Anixart

/// Чистые помощники `SibnetResolver` — без сети.
///
/// Покрыта ровно та логика, которую reference-клиент
/// (`Anixapp-Community/anixapp`, `electron/lib/direct-video-link.js`) выполняет
/// в `extractSibnetSrcPath` / `isSibnetUnavailableHtml` / `followSibnetLocation`:
/// извлечение пути видео из HTML-образцов, детект «видео удалено», нормализация
/// относительного URL, выбор следующего `Location` и признак медиа-`Content-Type`.
/// Сетевой `resolve(...)` здесь не вызывается: `video.sibnet.ru` с нашей сети
/// закрыт (`403`), а тесты должны быть детерминированными.
final class SibnetResolverTests: XCTestCase {

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    /// Базовая страница: подписанный `shell.php` с хоста `video.sibnet.ru`.
    private var shellURL: URL {
        makeURL("https://video.sibnet.ru/shell.php?videoid=2665026&d=2026112423&s=abc&ip=1.2.3.4")
    }

    /// HTML вида, который описывает reference-клиент: `player.src([{ src: "/v/....mp4" }])`.
    private var playerHTML: String {
        #"""
        <!DOCTYPE html><html><body>
        <script type="text/javascript">
          player.src([{ src: "/v/2026/2665026.mp4", type: "video/mp4" }]);
        </script>
        </body></html>
        """#
    }

    // MARK: - 1. Путь видео из HTML: приоритет регулярок

    func testSrcPathPriority() {
        // Приоритет 1: `player.src([{ src: "/..."`.
        XCTAssertEqual(SibnetResolver.srcPath(in: playerHTML), "/v/2026/2665026.mp4")

        // Приоритет 1 важнее общего `src:`: первым идёт player.src.
        let withBoth = #"""
        <script>var other = { src: "/v/2026/wrong.mp4" };</script>
        <script>player.src([{ src: "/v/2026/right.mp4", type: "video/mp4" }]);</script>
        """#
        XCTAssertEqual(SibnetResolver.srcPath(in: withBoth), "/v/2026/right.mp4")

        // Приоритет 2: `src: "/v/....mp4"` важнее общего `src: "/..."`.
        let mp4BeforeGeneric = #"""
        <script>var a = { src: "/v/2026/first.mp4" };</script>
        <script>var b = { src: "/other/path" };</script>
        """#
        XCTAssertEqual(SibnetResolver.srcPath(in: mp4BeforeGeneric), "/v/2026/first.mp4")

        // Приоритет 3: `src: "/shell.php?..."` (запасной вариант — видео отдаёт сам shell).
        let shell = #"<script>var v = { src: "/shell.php?videoid=2665026&s=abc" };</script>"#
        XCTAssertEqual(SibnetResolver.srcPath(in: shell), "/shell.php?videoid=2665026&s=abc")
    }

    func testSrcPathFormats() {
        // Одинарные кавычки.
        XCTAssertEqual(SibnetResolver.srcPath(in: #"<script>var v = { src: '/v/2026/single.mp4' };</script>"#),
                       "/v/2026/single.mp4")

        // Старый/запасной формат `file:` с shell.php.
        XCTAssertEqual(SibnetResolver.srcPath(in: #"new Playerjs({ file: "/shell.php?videoid=9" })"#),
                       "/shell.php?videoid=9")

        // Общий `src: "/..."` — последняя ветка для нестандартного пути.
        XCTAssertEqual(SibnetResolver.srcPath(in: #"<script>var v = { src: "/custom/stream" };</script>"#),
                       "/custom/stream")

        // Страница без плеера и пустое значение — пути нет.
        XCTAssertNil(SibnetResolver.srcPath(in: "<html><body>no player</body></html>"))
        XCTAssertNil(SibnetResolver.srcPath(in: #"<script>var v = { src: "" };</script>"#))
    }

    // MARK: - 2. Детект «видео удалено»

    func testUnavailableHTML() {
        // Русские тексты страницы ошибки Sibnet.
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<div>Видео удалено</div>"))
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<div>Видео не найдено</div>"))
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<div>ВИДЕО НЕ СУЩЕСТВУЕТ</div>"))
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<div>Видео удалено пользователем</div>"))

        // Английские варианты — тоже маркеры, без учёта регистра.
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<h1>Video deleted</h1>"))
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<h1>VIDEO NOT FOUND</h1>"))
        XCTAssertTrue(SibnetResolver.isUnavailableHTML("<h1>Access Denied</h1>"))

        // Обычная страница плеера — не «удалено».
        XCTAssertFalse(SibnetResolver.isUnavailableHTML(playerHTML))
        XCTAssertFalse(SibnetResolver.isUnavailableHTML("<html><body>player ok</body></html>"))
    }

    // MARK: - 3. Нормализация относительного URL

    func testAbsoluteURL() {
        // Относительный путь достраивается от shell.php (хост video.sibnet.ru).
        XCTAssertEqual(SibnetResolver.absoluteURL("/v/2026/a.mp4", relativeTo: shellURL)?.absoluteString,
                       "https://video.sibnet.ru/v/2026/a.mp4")
        // Путь без ведущего слэша — тоже относительный.
        XCTAssertEqual(SibnetResolver.absoluteURL("v/2026/b.mp4", relativeTo: shellURL)?.absoluteString,
                       "https://video.sibnet.ru/v/2026/b.mp4")
        // Protocol-relative ссылка получает схему базового URL.
        XCTAssertEqual(SibnetResolver.absoluteURL("//cdn.sibnet.ru/v/c.mp4", relativeTo: shellURL)?.absoluteString,
                       "https://cdn.sibnet.ru/v/c.mp4")
        // Абсолютный URL берётся как есть.
        XCTAssertEqual(SibnetResolver.absoluteURL("https://video.sibnet.ru/v/d.mp4?sig=1", relativeTo: shellURL)?.absoluteString,
                       "https://video.sibnet.ru/v/d.mp4?sig=1")
        // HTML-сущность `&amp;` и JSON-экранирование `\/` разворачиваются.
        XCTAssertEqual(SibnetResolver.absoluteURL("/shell.php?videoid=1&amp;s=abc", relativeTo: shellURL)?.absoluteString,
                       "https://video.sibnet.ru/shell.php?videoid=1&s=abc")
        XCTAssertEqual(SibnetResolver.absoluteURL(#"\/v\/2026\/e.mp4"#, relativeTo: shellURL)?.absoluteString,
                       "https://video.sibnet.ru/v/2026/e.mp4")
        // Пустое значение ссылки не даёт.
        XCTAssertNil(SibnetResolver.absoluteURL("", relativeTo: shellURL))
        XCTAssertNil(SibnetResolver.absoluteURL("   ", relativeTo: shellURL))
    }

    // MARK: - 4. Выбор следующего Location

    func testRedirectURL() {
        let base = makeURL("https://video.sibnet.ru/v/2026/a.mp4")

        XCTAssertEqual(SibnetResolver.redirectURL(location: "https://cdn.sibnet.ru/v/b.mp4",
                                                  relativeTo: base)?.absoluteString,
                       "https://cdn.sibnet.ru/v/b.mp4")
        XCTAssertEqual(SibnetResolver.redirectURL(location: "/v/2026/c.mp4", relativeTo: base)?.absoluteString,
                       "https://video.sibnet.ru/v/2026/c.mp4")
        // Относительный Location без слэша — от каталога текущего URL.
        XCTAssertEqual(SibnetResolver.redirectURL(location: "d.mp4", relativeTo: base)?.absoluteString,
                       "https://video.sibnet.ru/v/2026/d.mp4")
        XCTAssertEqual(SibnetResolver.redirectURL(location: "//cdn.sibnet.ru/v/e.mp4",
                                                  relativeTo: base)?.absoluteString,
                       "https://cdn.sibnet.ru/v/e.mp4")

        // HTML-страница в Location и не-http схемы отклоняются.
        XCTAssertNil(SibnetResolver.redirectURL(location: "/error.html", relativeTo: base))
        XCTAssertNil(SibnetResolver.redirectURL(location: "https://video.sibnet.ru/error.htm", relativeTo: base))
        XCTAssertNil(SibnetResolver.redirectURL(location: "javascript:alert(1)", relativeTo: base))
        XCTAssertNil(SibnetResolver.redirectURL(location: "", relativeTo: base))
    }

    // MARK: - 5. Content-Type готового медиа

    func testVideoContentType() {
        XCTAssertTrue(SibnetResolver.isVideoContentType("video/mp4"))
        XCTAssertTrue(SibnetResolver.isVideoContentType("video/MP2T"))
        XCTAssertTrue(SibnetResolver.isVideoContentType("application/octet-stream"))
        XCTAssertTrue(SibnetResolver.isVideoContentType("Application/MP4"))
        XCTAssertTrue(SibnetResolver.isVideoContentType("application/vnd.apple.mpegurl"))

        XCTAssertFalse(SibnetResolver.isVideoContentType("text/html; charset=utf-8"))
        XCTAssertFalse(SibnetResolver.isVideoContentType("application/json"))
        XCTAssertFalse(SibnetResolver.isVideoContentType(""))
        XCTAssertFalse(SibnetResolver.isVideoContentType(nil))
    }

    // MARK: - 6. Нормализация порта

    func testRemovingDefaultPort() {
        XCTAssertEqual(SibnetResolver.removingDefaultPort(makeURL("https://video.sibnet.ru:443/v/a.mp4")).absoluteString,
                       "https://video.sibnet.ru/v/a.mp4")
        // Не-default порт и http не трогаем.
        XCTAssertEqual(SibnetResolver.removingDefaultPort(makeURL("https://video.sibnet.ru:8443/v/a.mp4")).absoluteString,
                       "https://video.sibnet.ru:8443/v/a.mp4")
        XCTAssertEqual(SibnetResolver.removingDefaultPort(makeURL("http://video.sibnet.ru:80/v/a.mp4")).absoluteString,
                       "http://video.sibnet.ru:80/v/a.mp4")
    }

    // MARK: - 7. Контракт резолвера

    func testSurface() {
        XCTAssertEqual(SibnetResolver.providerName, "Sibnet")
        // Referer экрана — корень видеохоста (как в `PlaybackTarget`), а Referer
        // запросов к shell.php — корень sibnet.ru (так делает reference-клиент).
        XCTAssertEqual(SibnetResolver.referer?.absoluteString, "https://video.sibnet.ru/")
        XCTAssertEqual(SibnetResolver.pageReferer, "https://sibnet.ru/")

        XCTAssertEqual(SibnetResolver.srcPatterns.count, 6, "шесть регулярок reference-клиента")
        XCTAssertTrue(SibnetResolver.unavailableMarkers.contains("видео удалено"))
        XCTAssertTrue(SibnetResolver.unavailableMarkers.contains("video not found"))
        XCTAssertTrue(SibnetResolver.pageAccept.contains("application/xml;q=0.9"))
        XCTAssertTrue(SibnetResolver.pageAcceptLanguage.contains("ru-RU"))
        XCTAssertFalse(SibnetResolver.mobileSafariUserAgent.isEmpty)
        XCTAssertFalse(SibnetResolver.androidWebViewUserAgent.isEmpty)
        // Медиазапросы AVPlayer идут с Referer на видео-хост и браузерным UA:
        // Sibnet-CDN проверяет источник (см. reference hls-media-context).
        XCTAssertEqual(SibnetResolver.mediaHTTPHeaders["Referer"], "https://video.sibnet.ru/")
        XCTAssertEqual(SibnetResolver.mediaHTTPHeaders["User-Agent"],
                       SibnetResolver.desktopChromeUserAgent)
        XCTAssertNotEqual(SibnetResolver.mobileSafariUserAgent,
                          SibnetResolver.androidWebViewUserAgent)
    }

    // MARK: - 8. Чужой хост отклоняется без сети

    func testRejectsForeignHost() async {
        do {
            _ = try await SibnetResolver.resolve(url: makeURL("https://example.com/shell.php?videoid=1"),
                                                 title: "1 серия")
            XCTFail("чужой хост не должен резолвиться")
        } catch let error as PlaybackError {
            guard case .resolutionFailed = error else {
                XCTFail("ожидался resolutionFailed, пришло \(error)")
                return
            }
            XCTAssertTrue(error.localizedDescription.contains("Sibnet"))
        } catch {
            XCTFail("ожидался PlaybackError, пришло \(error)")
        }
    }
}
