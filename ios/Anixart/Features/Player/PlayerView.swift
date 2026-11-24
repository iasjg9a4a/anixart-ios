import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Состояние экрана

/// Фаза экрана плеера.
private enum PlayerPhase: Equatable {
    /// Ждём, пока WKWebView/AVPlayer покажет первый кадр.
    case loading
    /// Плеер на экране: заглушек и ошибок нет.
    case ready
    /// Ошибка воспроизведения: пользовательский текст из `PlaybackError`
    /// и техническая причина (текст WKWebView) для мелкой подписи.
    case failed(PlaybackError, detail: String?)
}

// MARK: - Экран

/// Полноэкранный плеер Anixart.
///
/// Ссылки Anixart неоднородны, поэтому сюда приходит уже разобранный `PlaybackTarget`
/// (см. `PlaybackResolver`): HTML-страницы сторонних плееров (Kodik, Sibnet, AniLibria,
/// RuTube) показывает `PlayerWebView` — iframe-обёртка с нужным Referer, — а прямые
/// `m3u8`/`mp4` играет нативный `AVPlayer` (пока это простая заглушка `AVPlayerView`,
/// её заменит `NativePlayerView` — см. комментарий у типа).
///
/// Пока web-плеер не прислал `onLoaded`, на экране висит спиннер. Если за 20 секунд
/// плеер не загрузился (или WKWebView сообщил об ошибке), вместо видео показывается
/// ошибка с кнопкой «Открыть в Safari»: так пользователь не остаётся с чёрным экраном.
///
/// У Kodik качество задано прямо в пути подписанной ссылки (`…/{hash}/720p?d=…`):
/// смена качества пересобирает ссылку прокси и перезагружает `PlayerWebView`.
/// У нативного HLS отдельный механизм — `VideoQualityMenu` из master-плейлиста.
struct PlayerView: View {
    let target: PlaybackTarget

    /// Контекст серии для `PlaybackProgress`: по нему нативный плеер продолжит
    /// просмотр с сохранённого места и отметит серию просмотренной. У `PlayerWebView`
    /// прогресса нет — для HTML-плееров эти поля не используются.
    private let releaseId: Int?
    private let sourceId: Int?
    private let position: Int?
    /// Идентификатор озвучки — нужен для «следующей серии».
    private let typeId: Int?

    @Environment(\.dismiss) private var dismiss

    @State private var phase: PlayerPhase = .loading
    @State private var pipController: PiPController?

    /// Найденный «нативный» поток (RuTube/AnixPlayer/Sibnet/AniLibria) — если резолвер
    /// смог достать m3u8, играем через AVPlayer вместо WebView.
    @State private var nativeStreamURL: URL?
    /// Позиция текущей серии (меняется при переходе к следующей).
    @State private var currentPosition: Int?
    /// Заголовок текущей серии.
    @State private var currentTitle: String = ""
    /// Следующая серия, если она найдена сервисом.
    @State private var nextEpisode: EpisodeRef?
    @State private var qualities: [VideoQualityVariant] = []
    @State private var selectedQuality: VideoQualityVariant?

    /// Качества HTML-плеера (Kodik): метки вида «360p»…«1080p».
    @State private var webQualities: [String] = []
    /// Текущее качество web-плеера — оно подсвечивается в меню.
    @State private var selectedWebQuality: String?
    /// Ссылка, которую сейчас открывает `PlayerWebView` (меняется при смене качества).
    @State private var webURL: URL?
    /// Токен перезагрузки: новый id у `PlayerWebView` — новый `WKWebView` с новой ссылкой.
    @State private var webReloadToken = UUID()

    /// Сколько ждём загрузку встроенного плеера, прежде чем предложить Safari.
    private static let loadTimeoutNanoseconds: UInt64 = 20 * 1_000_000_000

    /// Полный набор меток качества, которые Kodik ставит в путь ссылки.
    private static let kodikQualityLadder = ["144p", "240p", "360p", "480p", "720p", "1080p"]

    /// «Стандартный» набор Kodik — его и предлагаем в меню web-плеера.
    private static let kodikMenuQualities: Set<String> = ["360p", "480p", "720p", "1080p"]

    /// Те же качества множеством: быстрая проверка последнего сегмента пути.
    private static let kodikKnownQualities: Set<String> = ["144p", "240p", "360p", "480p", "720p", "1080p"]

    /// Ключ `UserDefaults` с последним выбранным качеством Kodik.
    private static let kodikQualityDefaultsKey = "anixart.kodik.quality"

    init(target: PlaybackTarget,
         releaseId: Int? = nil,
         sourceId: Int? = nil,
         position: Int? = nil,
         typeId: Int? = nil) {
        self.target = target
        self.releaseId = releaseId
        self.sourceId = sourceId
        self.position = position
        self.typeId = typeId
        _currentPosition = State(initialValue: position)
        _currentTitle = State(initialValue: target.title)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                player

                overlay
            }
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    closeButton
                }
                if qualities.count > 1 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        VideoQualityMenu(variants: qualities, current: selectedQuality) { variant in
                            selectQuality(variant)
                        }
                    }
                }
                if showsWebQualityMenu {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        webQualityMenu
                    }
                }
                if pipController != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            togglePiP()
                        } label: {
                            Image(systemName: "pip.enter")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await preparePlayback() }
    }

    // MARK: - Следующая серия

    private func handlePlaybackFinished() {
        guard let releaseId, let sourceId, let typeId, let position = currentPosition else { return }
        Task {
            if let next = await NextEpisodeService.shared.nextEpisode(
                after: position, releaseId: releaseId, typeId: typeId, sourceId: sourceId
            ) {
                nextEpisode = next
            }
        }
    }

    private func playNext(_ next: EpisodeRef) {
        nextEpisode = nil
        phase = .loading
        Task {
            do {
                let episode = try await NextEpisodeService.shared.resolvedTarget(for: next)
                guard let raw = episode.url, let url = URL(string: raw) else {
                    throw PlaybackError.emptyURL
                }
                let resolved = PlaybackResolver.resolve(
                    url: url,
                    iframe: episode.iframe == true,
                    title: next.title,
                    sourceName: nil
                )
                currentPosition = next.position
                currentTitle = next.title
                switch resolved.kind {
                case .hls(let stream):
                    nativeStreamURL = stream
                    await loadQualities(for: stream)
                case .web(let web):
                    nativeStreamURL = web
                    await loadQualities(for: web)
                case .youtube:
                    fail(.playbackUnavailable, detail: "Следующая серия доступна только в нативном плеере")
                }
            } catch {
                fail(.playbackUnavailable, detail: error.localizedDescription)
            }
        }
    }

    private var nextEpisodeButton: some View {
        Group {
            if let next = nextEpisode {
                Button {
                    playNext(next)
                } label: {
                    Label("Следующая: \(next.title)", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                }
                .padding(16)
            }
        }
    }

    /// Сохранённая позиция этой серии (0, если её нет).
    private var savedPosition: Int {
        guard let releaseId, let sourceId, let episodePosition = currentPosition else { return 0 }
        return PlaybackProgress.shared.position(releaseId: releaseId, sourceId: sourceId, position: episodePosition) ?? 0
    }

    private func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stop()
        } else {
            pip.start()
        }
    }

    // MARK: - Контент

    @ViewBuilder
    private var player: some View {
        if let nativeStreamURL {
            nativePlayer(url: nativeStreamURL)
        } else {
            switch target.kind {
            case .hls(let url):
                nativePlayer(url: url)
            case .web, .youtube:
                webPlayer
            }
        }
    }

    private func nativePlayer(url: URL) -> some View {
        NativePlayerView(
                url: url,
                title: target.title,
                onFinished: {
                    handlePlaybackFinished()
                },
                startPosition: savedPosition,
                onProgress: nil,
                onReady: {
                    phase = .ready
                },
                releaseId: releaseId,
                sourceId: sourceId,
                episodePosition: currentPosition,
                onPlayerLayerReady: { layer in
                    if PiPController.isSupported {
                        pipController = PiPController(playerLayer: layer)
                    }
                }
        )
    }

    /// Небольшая панель под HTML-плеером: сторонние плееры (Kodik и т.п.) иногда
    /// отвечают своей страницей ошибки, которую нельзя прочитать из iframe.
    /// Даём пользователю выход: открыть в Safari или вернуться и выбрать другой источник.
    private var webFallbackBar: some View {
        HStack(spacing: 10) {
            Button {
                openInSafari()
            } label: {
                Label("Safari", systemImage: "safari")
            }
            Button {
                dismiss()
            } label: {
                Label("Сменить источник", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6), in: Capsule())
        .padding(.bottom, 10)
    }

    private var webPlayer: some View {
        PlayerWebView(
            target: webPlaybackTarget,
            onLoaded: {
                phase = .ready
            },
            onError: { message in
                fail(.playbackUnavailable, detail: message)
            }
        )
        // Смена качества пересоздаёт WKWebView, иначе `updateUIView` не перезагрузит страницу.
        .id(webReloadToken)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Место, с которого начинается нативное воспроизведение.
    ///
    /// Прогресс хранится только для известной серии (`releaseId` + `sourceId` + `position`):
    /// для web-плееров позиция недоступна, поэтому там всегда 0.

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityLabel("Закрыть")
        .accessibilityIdentifier("player-close")
    }

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .loading:
            PlayerLoadingView(providerName: target.providerName)
        case .ready:
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    nextEpisodeButton
                }
            }
        case .failed(let error, let detail):
            PlayerErrorView(
                message: error.errorDescription ?? "Воспроизведение недоступно",
                detail: detail,
                onOpenInSafari: openInSafari,
                onClose: { dismiss() }
            )
        }
    }

    // MARK: - Подготовка источника

    /// Пытается получить нативный HLS у провайдеров, которые отдают HTML-страницу
    /// (Sibnet/AniLibria/RuTube/AnixPlayer). Если не удалось — остаёмся на WebView.
    ///
    /// Kodik идёт через прокси `anixmirai.com/iframe` и остаётся в WebView; качество
    /// у него берётся из пути ссылки — меню готовит `prepareWebQuality(for:)`.
    private func preparePlayback() async {
        switch target.kind {
        case .hls(let url):
            nativeStreamURL = url
            await loadQualities(for: url)
        case .youtube:
            await watchLoadTimeout()
        case .web(let proxyURL):
            prepareWebQuality(for: proxyURL)
            let original = unwrapProxyURL(proxyURL)
            let provider = target.providerName.lowercased()
            do {
                let resolved: PlaybackTarget
                if provider.contains("sibnet") {
                    resolved = try await SibnetResolver.resolve(url: original, title: target.title)
                } else if provider.contains("libria") || provider.contains("anilibria") {
                    resolved = try await AniLibriaResolver.resolve(url: original, title: target.title)
                } else if provider.contains("rutube") {
                    resolved = try await RutubeResolver.resolve(url: original, title: target.title)
                } else if provider.contains("anixplayer") || provider.contains("tsm") {
                    resolved = try await AnixPlayerResolver.resolve(url: original, title: target.title)
                } else {
                    await watchLoadTimeout()
                    return
                }
                if case .hls(let streamURL) = resolved.kind {
                    nativeStreamURL = streamURL
                    // Нативный поток: меню качества Kodik больше не нужно.
                    webQualities = []
                    webURL = nil
                    phase = .loading
                    await loadQualities(for: streamURL)
                    return
                }
            } catch {
                // HTML-плеер может сработать — молча откатываемся на WebView.
            }
            await watchLoadTimeout()
        }
    }

    /// Достаёт исходную ссылку из прокси `anixmirai.com/iframe?url=...`.
    private func unwrapProxyURL(_ url: URL) -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let original = URL(string: raw) else {
            return url
        }
        return original
    }

    private func loadQualities(for url: URL) async {
        guard url.pathExtension.lowercased() == "m3u8" else {
            qualities = []
            return
        }
        do {
            let variants = try await VideoQualitySelector.variants(from: url)
            qualities = variants
            selectedQuality = VideoQualitySelector.preferred(in: variants) ?? variants.first
        } catch {
            qualities = []
        }
    }

    private func selectQuality(_ variant: VideoQualityVariant) {
        selectedQuality = variant
        VideoQualitySelector.remember(variant)
        nativeStreamURL = variant.url
    }

    // MARK: - Качество web-плеера (Kodik)

    /// Ссылка, которая сейчас открыта в `PlayerWebView`: после смены качества — новая.
    private var currentWebURL: URL? {
        if let url = webURL { return url }
        if case .web(let url) = target.kind { return url }
        return nil
    }

    /// Цель для `PlayerWebView`: исходный `target`, но с пересобранной ссылкой качества.
    ///
    /// Для YouTube качества нет (`currentWebURL` пуст) — отдаём `target` как есть.
    private var webPlaybackTarget: PlaybackTarget {
        guard let url = currentWebURL else { return target }
        return PlaybackTarget(
            kind: .web(url),
            title: target.title,
            providerName: target.providerName,
            referer: target.referer
        )
    }

    /// Меню качества показываем, только когда играет HTML-плеер с известным качеством.
    private var showsWebQualityMenu: Bool {
        nativeStreamURL == nil && !webQualities.isEmpty
    }

    /// Меню качества Kodik в toolbar: метка текущего качества и список вариантов.
    private var webQualityMenu: some View {
        Menu {
            ForEach(webQualities, id: \.self) { quality in
                Button {
                    selectWebQuality(quality)
                } label: {
                    if quality == selectedWebQuality {
                        Label(quality, systemImage: "checkmark")
                    } else {
                        Text(quality)
                    }
                }
            }
        } label: {
            Image(systemName: "4k.tv")
        }
        .tint(Theme.accent)
        .accessibilityLabel("Качество видео")
    }

    /// Готовит меню качества web-плеера: качество Kodik берётся из пути ссылки.
    ///
    /// При открытии подсвечиваем текущее качество из ссылки — сохранённый ранее
    /// выбор её не подменяет (`d`/`s` — подпись Kodik, переписывать путь без
    /// действия пользователя нельзя). Сохранённое значение — фолбэк на случай
    /// ссылки без качества.
    private func prepareWebQuality(for url: URL) {
        webQualities = availableWebQualities(for: url)
        selectedWebQuality = kodikQuality(in: url) ?? rememberedWebQuality
    }

    /// Качества, между которыми можно переключаться у HTML-плеера.
    ///
    /// Kodik ставит качество в путь подписанной ссылки:
    /// `https://kodikplayer.com/seria/{id}/{hash}/{quality}?d=…&s=…`.
    /// Если последний сегмент пути — не качество, меню не нужно (пустой список).
    private func availableWebQualities(for url: URL) -> [String] {
        guard let current = kodikQuality(in: url) else { return [] }
        // 144p/240p — старые ролики Kodik: для них предлагаем весь известный набор,
        // иначе текущее качество не попадёт в меню и его нечем подсветить.
        guard Self.kodikMenuQualities.contains(current) else {
            return Self.kodikQualityLadder
        }
        return Self.kodikQualityLadder.filter { Self.kodikMenuQualities.contains($0) }
    }

    /// Качество из ссылки Kodik — последний сегмент пути (`…/{hash}/720p`).
    ///
    /// Ссылка может быть как исходной, так и обёрнутой в прокси Anixart
    /// (`anixmirai.com/iframe?url=<encoded>`): прокси разворачиваем.
    private func kodikQuality(in url: URL) -> String? {
        let segments = unwrapProxyURL(url).path.split(separator: "/")
        guard let last = segments.last.map({ String($0).lowercased() }),
              Self.kodikKnownQualities.contains(last) else {
            return nil
        }
        return last
    }

    /// Сохранённый выбор качества Kodik (`anixart.kodik.quality`).
    private var rememberedWebQuality: String? {
        let value = UserDefaults.standard.string(forKey: Self.kodikQualityDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Пересобирает ссылку Kodik с новым качеством и снова оборачивает её в прокси.
    ///
    /// Меняется только последний сегмент пути: `d`, `s`, `ip` — подпись Kodik
    /// для этой серии, их не трогаем.
    private func kodikURL(replacingQualityIn url: URL, with quality: String) -> URL? {
        let original = unwrapProxyURL(url)
        guard var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        // Ищем последний непустой сегмент: путь может заканчиваться слэшем.
        guard let qualityIndex = segments.lastIndex(where: { !$0.isEmpty }),
              Self.kodikKnownQualities.contains(segments[qualityIndex].lowercased()) else {
            return nil
        }
        segments[qualityIndex] = quality
        components.path = segments.joined(separator: "/")
        guard let rebuilt = components.url else { return nil }
        // Kodik открывается только через прокси Anixart: прямой GET отдаёт 500.
        return PlaybackResolver.proxied(rebuilt) ?? rebuilt
    }

    /// Смена качества Kodik: пересобираем прокси-ссылку и перезагружаем WKWebView.
    private func selectWebQuality(_ quality: String) {
        guard quality != selectedWebQuality,
              let sourceURL = currentWebURL,
              let rebuilt = kodikURL(replacingQualityIn: sourceURL, with: quality) else {
            return
        }
        selectedWebQuality = quality
        webURL = rebuilt
        webReloadToken = UUID()
        phase = .loading
        UserDefaults.standard.set(quality, forKey: Self.kodikQualityDefaultsKey)
        // Новая страница получает собственные 20 секунд до ошибки.
        Task { await watchLoadTimeout() }
    }

    // MARK: - Загрузка и ошибки

    /// Страховка от «вечного» спиннера: таймер стартует с появлением экрана,
    /// отменяется вместе с ним (`Task.sleep` бросает `CancellationError`) и теряет
    /// смысл, как только плеер прислал `onLoaded` и фаза сменилась на `.ready`.
    ///
    /// После смены качества web-плеер перезагружается: старый сторож ждал уже
    /// другую страницу, поэтому при смене токена он молча выходит — таймаут
    /// заново запускает `selectWebQuality(_:)`.
    private func watchLoadTimeout() async {
        let reloadToken = webReloadToken
        do {
            try await Task.sleep(nanoseconds: Self.loadTimeoutNanoseconds)
        } catch {
            return
        }
        guard phase == .loading else { return }
        guard reloadToken == webReloadToken else { return }
        fail(.playbackUnavailable, detail: "Плеер не загрузился за 20 секунд. Попробуйте открыть серию в Safari.")
    }

    private func fail(_ error: PlaybackError, detail: String? = nil) {
        phase = .failed(error, detail: detail)
    }

    /// Открыть исходную ссылку в Safari — единственный выход, если встроенный плеер
    /// не поднялся (Kodik и YouTube в WKWebView работают не всегда).
    private func openInSafari() {
        guard let url = PlaybackResolver.externalURL(for: target) else { return }
        // UIApplication — единственный способ открыть Safari; по стилю UIKit во вьюхах
        // не приветствуется, но для кнопки ошибки альтернативы в SwiftUI нет.
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }
}

// MARK: - Совместимость

extension PlayerView {
    /// Старый вызов `PlayerView(url:title:)`: цель разбирается по расширению ссылки.
    /// Нужен для мест, где ещё нет `Episode` (deep links, тесты).
    init(url: URL, title: String) {
        self.init(target: PlaybackResolver.fallbackTarget(for: url, title: title))
    }
}

// MARK: - Служебные вью плеера

private struct PlayerLoadingView: View {
    let providerName: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Theme.accent)

            Text("Загрузка видео")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(providerName)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82))
    }
}

/// Экран ошибки: текст `PlaybackError`, техническая причина и выход в Safari.

private struct PlayerErrorView: View {
    let message: String
    let detail: String?
    let onOpenInSafari: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)

            Text("Не удалось воспроизвести")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onOpenInSafari) {
                Text("Открыть в Safari")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Theme.accent, in: Capsule())
            }

            Button("Закрыть", action: onClose)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
