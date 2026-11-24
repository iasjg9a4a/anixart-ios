import Foundation

/// Как именно показывать конкретную серию.
///
/// Anixart отдаёт ссылки на разные системы: часть — это HTML-страницы сторонних плееров
/// (Kodik, Sibnet, AniLibria), часть — прямые HLS-потоки (RuTube, AnixPlayer), часть —
/// YouTube-встраивания. `PlaybackTarget` — результат разбора такой ссылки.
enum PlaybackKind: Equatable, Sendable {
    /// HTML-страница плеера: показываем в WKWebView (при необходимости — через iframe-обёртку,
    /// чтобы выставить корректный Referer/Origin, как делает оригинальное приложение).
    case web(URL)
    /// Прямой поток HLS/MP4: проигрываем нативно через AVPlayer.
    case hls(URL)
    /// YouTube: грузим iframe-API страницу с нужным videoId.
    case youtube(videoId: String)
}

/// Вариант качества прямого потока (Kodik ftor, AniLibria API, AnixPlayer, RuTube master).
///
/// Плеер показывает меню качества, только если вариантов больше одного: выбор
/// просто подменяет URL у AVPlayer, без повторного резолва.
struct PlaybackVariant: Equatable, Identifiable, Sendable {
    /// Подпись для меню: `1080p`, `720p`, `480p`, `360p`, `auto`.
    let quality: String
    /// Прямая ссылка потока этого качества.
    let url: URL

    var id: String { quality }
}

/// Цель воспроизведения — значение без ссылок на UI и сеть, поэтому её можно
/// отдавать между акторами (`EpisodeResolutionCache` хранит готовые цели).
struct PlaybackTarget: Equatable, Sendable {
    let kind: PlaybackKind
    let title: String
    /// Имя источника («Kodik», «Sibnet», «Libria»…). Нужно для UI и логов.
    let providerName: String
    /// Referer, который ожидает плеер (для iframe-обёртки и запросов к API).
    let referer: URL?
    /// Известные варианты качества (`nil`/меньше двух — меню не показываем).
    var variants: [PlaybackVariant]?
    /// HTTP-заголовки для запросов нативного плеера к самому потоку.
    ///
    /// `AVPlayer` не даёт публичного API на `Referer`/`User-Agent`, но часть
    /// CDN (Sibnet) проверяет источник и без них отдаёт 403/пустой поток.
    /// Заголовки применяются в `NativePlayerView` через ключ
    /// `AVURLAssetHTTPHeaderFieldsKey`; `nil` — поток не требует заголовков.
    var httpHeaders: [String: String]?

    init(kind: PlaybackKind,
         title: String,
         providerName: String,
         referer: URL?,
         variants: [PlaybackVariant]? = nil,
         httpHeaders: [String: String]? = nil) {
        self.kind = kind
        self.title = title
        self.providerName = providerName
        self.referer = referer
        self.variants = variants
        self.httpHeaders = httpHeaders
    }
}

/// Известные системы воспроизведения Anixart 11.
enum VideoProvider: String, CaseIterable {
    case kodik
    case sibnet
    case libria
    case rutube
    case anixplayer
    case youtube
    case unknown

    static func detect(sourceName: String?, url: URL?) -> VideoProvider {
        let name = (sourceName ?? "").lowercased()
        if name.contains("kodik") { return .kodik }
        if name.contains("sibnet") { return .sibnet }
        if name.contains("libria") || name.contains("anilibria") || name.contains("liberty") { return .libria }
        if name.contains("rutube") { return .rutube }
        if name.contains("anixplayer") || name.contains("studiomir") { return .anixplayer }
        if name.contains("youtube") { return .youtube }

        guard let host = url?.host?.lowercased(), !host.isEmpty else { return .unknown }
        if host.contains("kodik") { return .kodik }
        if host.contains("sibnet") { return .sibnet }
        if host.contains("libria") { return .libria }
        if host.contains("rutube") { return .rutube }
        if host.contains("studiomir") { return .anixplayer }
        if host.contains("youtube") || host.contains("youtu.be") { return .youtube }
        return .unknown
    }
}

enum PlaybackError: LocalizedError, Equatable {
    case emptyURL
    case unsupportedProvider(String)
    case resolutionFailed(String)
    case playbackUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "Сервер не вернул ссылку на видео"
        case .unsupportedProvider(let name):
            return "Плеер «\(name)» пока не поддерживается"
        case .resolutionFailed(let reason):
            return "Не удалось получить ссылку на видео: \(reason)"
        case .playbackUnavailable:
            return "Воспроизведение недоступно для этой серии"
        }
    }
}
