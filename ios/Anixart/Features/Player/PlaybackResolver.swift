import Foundation

/// Разбор ссылки, которую сервер вернул в `episode/target/...`, в понятный плееру
/// `PlaybackTarget`.
///
/// Anixart не отдаёт однородные ссылки: у Kodik, Sibnet и AniLibria это HTML-страницы
/// плееров, у RuTube и AnixPlayer — прямые `m3u8`/`mp4`, у YouTube — встраивания.
/// Правила разбора вынесены из `PlayerView` в отдельный тип, чтобы их можно было
/// покрыть тестами и переиспользовать в других местах (например, в deep links).
enum PlaybackResolver {

    // MARK: - Константы

    /// Referer, который ожидают HTML-плееры Anixart.
    ///
    /// Оригинальное приложение подставляет свой сайт (`assets/player_default.html`
    /// грузится с этим baseURL), иначе Kodik отвечает 500.
    static let anixartReferer: URL? = URL(string: "https://anixart-app.com/")

    /// Referer для встраиваний YouTube.
    static let youtubeReferer: URL? = URL(string: "https://www.youtube.com/")

    /// Серверный прокси Anixart для HTML-плееров.
    ///
    /// Оригинальное приложение не грузит Kodik напрямую: прямой GET отдаёт `500`,
    /// а `https://anixmirai.com/iframe?url=<encoded>` возвращает готовую страницу
    /// «Веб-плеер», которая вставляет нужный iframe. Список разрешённых доменов
    /// прокси: kodik.*, alloha, sovetromantica, vkvideo, anixart.libria.fun.
    static let anixmiraiReferer: URL? = URL(string: "https://anixmirai.com/")
    static let proxyBase = "https://anixmirai.com/iframe?url="

    /// Расширения, которые проигрываются нативно через `AVPlayer`.
    private static let directStreamExtensions: Set<String> = ["m3u8", "mp4"]

    /// Оборачивает ссылку в прокси Anixart. `nil`, если собрать URL не удалось.
    static func proxied(_ url: URL) -> URL? {
        guard var components = URLComponents(string: proxyBase) else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }

    // MARK: - Разбор серии

    /// Строит `PlaybackTarget` по серии из `episode/target/...` и имени источника.
    ///
    /// - Parameters:
    ///   - episode: серия с подписанной ссылкой (`url`, `iframe`, `name`).
    ///   - sourceName: имя источника («Kodik», «Sibnet», «AniLibria»…). По нему
    ///     определяется плеер, если хост ссылки об этом ничего не говорит.
    ///   - title: заголовок для экрана плеера; по умолчанию `episode.displayName`.
    /// - Throws: `PlaybackError.emptyURL`, если сервер не вернул пригодную ссылку.
    static func resolve(episode: Episode, sourceName: String?, title: String? = nil) throws -> PlaybackTarget {
        let raw = episode.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw PlaybackError.emptyURL
        }
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw PlaybackError.emptyURL
        }

        return resolve(
            url: url,
            iframe: episode.iframe == true,
            title: title ?? episode.displayName,
            sourceName: sourceName
        )
    }

    /// Разбор уже проверенной ссылки.
    ///
    /// Правила применяются по порядку: известный HTML-плеер → прямой поток →
    /// YouTube → страница в `WKWebView` по умолчанию.
    ///
    /// - Parameter iframe: `true`, если сервер пометил ссылку как iframe-страницу;
    ///   для iframe правило прямого потока не применяется.
    static func resolve(url: URL, iframe: Bool, title: String, sourceName: String?) -> PlaybackTarget {
        let provider = VideoProvider.detect(sourceName: sourceName, url: url)

        switch provider {
        case .kodik:
            // Прямой Kodik в WebView отдаёт 500 — только через прокси Anixart.
            return PlaybackTarget(
                kind: .web(proxied(url) ?? url),
                title: title,
                providerName: displayName(of: .kodik),
                referer: anixmiraiReferer
            )
        case .libria:
            return PlaybackTarget(
                kind: .web(proxied(url) ?? url),
                title: title,
                providerName: displayName(of: .libria),
                referer: anixmiraiReferer
            )
        case .sibnet:
            return PlaybackTarget(
                kind: .web(url),
                title: title,
                providerName: displayName(of: .sibnet),
                referer: anixartReferer
            )
        default:
            break
        }

        if !iframe, isDirectStream(url) {
            return PlaybackTarget(
                kind: .hls(url),
                title: title,
                providerName: providerTitle(provider, sourceName: sourceName),
                referer: nil
            )
        }

        if let videoId = videoId(from: url) {
            return PlaybackTarget(
                kind: .youtube(videoId: videoId),
                title: title,
                providerName: displayName(of: .youtube),
                referer: youtubeReferer
            )
        }

        return PlaybackTarget(
            kind: .web(url),
            title: title,
            providerName: providerTitle(provider, sourceName: sourceName),
            referer: anixartReferer
        )
    }

    /// Резервный разбор «голой» ссылки — когда `Episode` нет под рукой
    /// (старые вызовы `PlaybackRequest(url:title:)`, deep links, тесты).
    static func fallbackTarget(for url: URL, title: String) -> PlaybackTarget {
        resolve(url: url, iframe: false, title: title, sourceName: nil)
    }

    // MARK: - Ссылки

    /// Ссылка для открытия вне приложения (Safari, внешний плеер).
    ///
    /// Для YouTube собираем обычную страницу просмотра: `videoId` самого плеера
    /// недостаточно.
    static func externalURL(for target: PlaybackTarget) -> URL? {
        switch target.kind {
        case .web(let url), .hls(let url):
            return url
        case .youtube(let videoId):
            return URL(string: "https://www.youtube.com/watch?v=\(videoId)")
        }
    }

    // MARK: - YouTube

    /// Достаёт идентификатор видео из ссылок `youtube.com/watch?v=ID`,
    /// `youtu.be/ID` и `youtube.com/embed/ID`.
    ///
    /// Возвращает `nil`, если ссылка не YouTube или идентификатора в ней нет.
    static func videoId(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), isYouTubeHost(host) else { return nil }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return firstPathComponent(of: url)
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let item = components.queryItems?.first(where: { $0.name == "v" }),
           let value = item.value,
           !value.isEmpty {
            return value
        }

        let path = url.path
        for prefix in ["/embed/", "/shorts/", "/v/"] where path.hasPrefix(prefix) {
            let identifier = String(path.dropFirst(prefix.count))
            let trimmed = identifier.split(separator: "/").first.map(String.init) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtu.be"
            || host.hasSuffix(".youtu.be")
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host.contains("youtube-nocookie.com")
    }

    private static func firstPathComponent(of url: URL) -> String? {
        let component = url.path.split(separator: "/").first.map(String.init) ?? ""
        let value = component.split(separator: "?").first.map(String.init) ?? component
        return value.isEmpty ? nil : value
    }

    // MARK: - Провайдеры

    /// Человеческое имя плеера. Используется в подписи источника на экране плеера.
    static func displayName(of provider: VideoProvider) -> String {
        switch provider {
        case .kodik:
            return "Kodik"
        case .sibnet:
            return "Sibnet"
        case .libria:
            return "Libria"
        case .rutube:
            return "RuTube"
        case .anixplayer:
            return "AnixPlayer"
        case .youtube:
            return "YouTube"
        case .unknown:
            return "Онлайн-плеер"
        }
    }

    /// Имя источника для неопознанных плееров: имя от сервера информативнее
    /// заглушки «Онлайн-плеер».
    private static func providerTitle(_ provider: VideoProvider, sourceName: String?) -> String {
        guard provider == .unknown,
              let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return displayName(of: provider)
        }
        return name
    }

    // MARK: - Прямые ссылки

    /// Ссылка ведёт прямо на видеофайл, а не на HTML-страницу плеера.
    private static func isDirectStream(_ url: URL) -> Bool {
        directStreamExtensions.contains(url.pathExtension.lowercased())
    }
}
