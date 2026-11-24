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
    /// Текущая цель воспроизведения.
    ///
    /// Не `let`: при смене качества и при выборе другой серии из шита плеер
    /// должен подменить ссылку/источник, не закрывая экран. `@State` заставляет
    /// SwiftUI перерисовать дерево и пересоздать `NativePlayerView` под новый URL.
    @State private var target: PlaybackTarget

    /// Контекст серии для `PlaybackProgress`: по нему нативный плеер продолжит
    /// просмотр с сохранённого места и отметит серию просмотренной. У `PlayerWebView`
    /// прогресса нет — для HTML-плееров эти поля не используются.
    private let releaseId: Int?
    private let sourceId: Int?
    private let position: Int?
    /// Идентификатор озвучки — нужен для «следующей серии» и списка серий.
    private let typeId: Int?

    @Environment(\.dismiss) private var dismiss

    @State private var phase: PlayerPhase = .loading
    @State private var pipController: PiPController?

    /// Шит со списком серий источника (открывается кнопкой в оверлее контролов).
    @State private var showsEpisodes = false

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
    /// С какого места начинать поток после пересоздания плеера (смена качества).
    /// Важнее сохранённого прогресса: перезапуск не должен откатывать видео назад.
    @State private var startPositionOverride: Int?

    /// Состояние нативного воспроизведения: мост между `AVPlayer` и SwiftUI-контролами.
    /// Один инстанс на экран: `NativePlayerView` подключает к нему свой плеер.
    @StateObject private var playback = NativePlaybackState()
    /// Видны ли контролы поверх видео (кнопки, слайдер, скорость, качество).
    @State private var controlsVisible = true
    /// Отладочный режим (CI-скриншоты, ручная проверка): контролы не автоскрываются.
    /// Включается аргументом запуска `-anixart-force-player-controls`.
    private let forceControlsVisible = ProcessInfo.processInfo.arguments.contains("-anixart-force-player-controls")
    /// Задача авто-скрытия контролов; отменяется при каждом новом показе.
    @State private var controlsHideTask: Task<Void, Never>?
    /// Всплывающая подсказка двойного тапа («−10 с» / «+10 с»).
    @State private var skipHint: String?
    @State private var skipHintTask: Task<Void, Never>?
    /// Контролы уже прятались хоть раз: первый показ держим 6 секунд, дальше — 4.
    @State private var hasAutoHiddenControls = false

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

    /// Первый показ контролов: 6 секунд. CI-скриншот `14-player-controls.png`
    /// снимается через 5 секунд после запуска — контролы должны быть в кадре.
    private static let initialControlsHideDelay: UInt64 = 6 * 1_000_000_000

    /// Авто-скрытие контролов после взаимодействия с плеером.
    private static let controlsHideDelay: UInt64 = 4 * 1_000_000_000

    /// Шаг перемотки двойным тапом по левой/правой трети видео.
    private static let skipStep: Double = 10

    /// Сколько висит подсказка о перемотке.
    private static let skipHintDuration: UInt64 = 800_000_000

    /// Полный набор меток качества, которые Kodik ставит в путь ссылки.
    private static let kodikQualityLadder = ["144p", "240p", "360p", "480p", "720p", "1080p"]

    /// «Стандартный» набор Kodik — его и предлагаем в меню web-плеера.
    private static let kodikMenuQualities: Set<String> = ["360p", "480p", "720p", "1080p"]

    /// Те же качества множеством: быстрая проверка последнего сегмента пути.
    private static let kodikKnownQualities: Set<String> = ["144p", "240p", "360p", "480p", "720p", "1080p"]

    /// Ключ `UserDefaults` с последним выбранным качеством Kodik.
    private static let kodikQualityDefaultsKey = "anixart.kodik.quality"

    /// Явное закрытие экрана: экран презентуется `fullScreenCover(item:)` из разных
    /// мест, и `@Environment(\.dismiss)` внутри `NavigationStack` в редких случаях
    /// не доходит до cover'а. Поэтому владелец презентации может передать свой
    /// обработчик — он гарантированно сбрасывает состояние презентации.
    private let onCloseExplicit: (() -> Void)?

    init(target: PlaybackTarget,
         releaseId: Int? = nil,
         sourceId: Int? = nil,
         position: Int? = nil,
         typeId: Int? = nil,
         onClose: (() -> Void)? = nil) {
        _target = State(initialValue: target)
        self.releaseId = releaseId
        self.sourceId = sourceId
        self.position = position
        self.typeId = typeId
        self.onCloseExplicit = onClose
        _currentPosition = State(initialValue: position)
        _currentTitle = State(initialValue: target.title)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Слои экрана: фон → видео → контролы. Внутри `nativePlayer`
                // те же zIndex повторяют порядок для видео/тапов/оверлея/подсказок.
                Color.black.ignoresSafeArea()
                    .zIndex(0)

                player
                    .zIndex(1)

                overlay
                    .zIndex(2)
            }
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            // У нативного видео есть свои контролы (закрыть, качество, скорость, PiP):
            // системный навбар дублировал бы крестик и заголовок двумя строками.
            .toolbar(usesCustomPlayerChrome ? .hidden : .visible, for: .navigationBar)
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
                // У web-плеера нет оверлея контролов, поэтому список серий
                // открываем кнопкой в навбаре (у нативного — кнопкой в оверлее).
                if showsWebEpisodeListButton {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showsEpisodes = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("Список серий")
                        .accessibilityIdentifier("player-episodes")
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
        // Свайп вниз не должен блокироваться: кроме крестика у пользователя
        // остаётся штатный способ закрыть модальный экран.
        .interactiveDismissDisabled(false)
        .preferredColorScheme(.dark)
        .task { await preparePlayback() }
        .onAppear {
            // Стартовый показ контролов — 6 секунд (CI снимает раньше).
            scheduleControlsHide(after: Self.initialControlsHideDelay)
        }
        .onDisappear {
            controlsHideTask?.cancel()
            skipHintTask?.cancel()
        }
        .onChange(of: playback.isPlaying) { isPlaying in
            guard isPlaying else {
                controlsHideTask?.cancel()
                controlsHideTask = nil
                return
            }
            // Стартовый показ держим 6 секунд с момента, когда видео реально пошло.
            guard controlsHideTask == nil, controlsVisible else { return }
            let delay = hasAutoHiddenControls ? Self.controlsHideDelay : Self.initialControlsHideDelay
            scheduleControlsHide(after: delay)
        }
        .onChange(of: playback.isSeeking) { isSeeking in
            if isSeeking {
                controlsHideTask?.cancel()
                controlsHideTask = nil
            } else if controlsVisible {
                scheduleControlsHide(after: Self.controlsHideDelay)
            }
        }
        // Серия готова к показу — заранее ищем следующую, чтобы кнопка
        // «Следующая серия» появилась сразу, а не только по концу серии.
        .onChange(of: phase) { newPhase in
            guard case .ready = newPhase else { return }
            Task { await prefetchNextEpisode() }
        }
        // Шит серий: показывается поверх плеера, сам закрывается после выбора.
        .sheet(isPresented: $showsEpisodes) {
            PlayerEpisodesSheet(
                releaseId: releaseId,
                typeId: typeId,
                sourceId: sourceId,
                currentPosition: currentPosition,
                onSelect: { episode in
                    playEpisode(episode)
                }
            )
        }
    }

    // MARK: - Закрытие плеера

    /// Закрывает экран и снимает все отложенные задачи.
    ///
    /// Раньше крестик просто вызывал `dismiss()`, а таймеры авто-скрытия и
    /// подсказки перемотки могли сработать уже после закрытия. Здесь плеер
    /// гарантированно закрывается в любой фазе: загрузка, воспроизведение, ошибка.
    private func closePlayer() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        skipHintTask?.cancel()
        skipHintTask = nil
        // Владелец презентации может передать явный обработчик — он надёжнее
        // `dismiss()` внутри `NavigationStack` (был баг: крестик не закрывал плеер).
        if let onCloseExplicit {
            onCloseExplicit()
        } else {
            dismiss()
        }
    }

    // MARK: - Следующая серия и выбор серии

    /// Вызывается по концу серии: показываем контролы и страхуемся, что
    /// следующая серия найдена (обычно она уже загружена заранее).
    private func handlePlaybackFinished() {
        // Конец серии: контролы показываем, иначе кнопку «Следующая серия»
        // в оверлее не найти — он мог успеть автоскрыться.
        revealControls()
        Task { await prefetchNextEpisode() }
    }

    /// Заранее ищет следующую серию, пока идёт текущая.
    ///
    /// `NextEpisodeService` кэширует список серий, поэтому повторные вызовы
    /// дешёвые. Кнопка в оверлее появляется сразу, как только серия найдена,
    /// а не только после её окончания.
    private func prefetchNextEpisode() async {
        guard nextEpisode == nil else { return }
        guard phase == .ready else { return }
        guard let releaseId, let sourceId, let typeId, let position = currentPosition else { return }
        let next = await NextEpisodeService.shared.nextEpisode(
            after: position,
            releaseId: releaseId,
            typeId: typeId,
            sourceId: sourceId
        )
        // Пока шёл запрос, пользователь мог сменить серию/качество.
        guard let next, phase == .ready, currentPosition == position else { return }
        nextEpisode = next
    }

    /// Играет серию, выбранную пользователем в списке серий.
    private func playEpisode(_ episode: Episode) {
        startPlayback(position: episode.position,
                      sourceId: episode.sourceId ?? sourceId,
                      title: episode.displayName)
    }

    /// Переход к «следующей серии» из оверлея.
    private func playNext(_ next: EpisodeRef) {
        startPlayback(position: next.position, sourceId: next.sourceId, title: next.title)
    }

    /// Переключает плеер на другую серию того же релиза.
    ///
    /// Ссылка на видео подписана под IP и живёт ограниченное время, поэтому
    /// свежий `episode/target` запрашивается в момент перехода (как раньше в
    /// `playNext`), а не берётся из списка серий. Пока идёт запрос — `.loading`.
    private func startPlayback(position newPosition: Int, sourceId newSourceId: Int?, title newTitle: String) {
        guard let releaseId, let sourceId = newSourceId ?? sourceId else { return }
        nextEpisode = nil
        phase = .loading
        Task {
            do {
                let ref = EpisodeRef(
                    releaseId: releaseId,
                    typeId: typeId,
                    sourceId: sourceId,
                    position: newPosition,
                    title: newTitle
                )
                let episode = try await NextEpisodeService.shared.resolvedTarget(for: ref)
                guard let raw = episode.url, let url = URL(string: raw) else {
                    throw PlaybackError.emptyURL
                }
                let resolved = PlaybackResolver.resolve(
                    url: url,
                    iframe: episode.iframe == true,
                    title: newTitle,
                    sourceName: nil
                )
                beginPlayback(resolved, position: newPosition, title: newTitle)
            } catch {
                fail(.playbackUnavailable, detail: error.localizedDescription)
            }
        }
    }

    /// Ставит готовую цель в плеер, сбрасывая состояние прошлой серии.
    ///
    /// Для нативного потока меняет `nativeStreamURL` — `.id` у `NativePlayerView`
    /// заставляет SwiftUI пересоздать его вместе с `AVPlayer`. Для web-плеера
    /// пересобирается `PlayerWebView` (новый токен перезагрузки).
    private func beginPlayback(_ newTarget: PlaybackTarget, position newPosition: Int?, title newTitle: String) {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        skipHintTask?.cancel()
        skipHintTask = nil
        nextEpisode = nil
        startPositionOverride = nil
        currentPosition = newPosition
        currentTitle = newTitle
        target = newTarget
        phase = .loading
        // Новую серию начинаем с видимыми контролами: иначе кнопку «Следующая»
        // на паузе или первом кадре не найти.
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }

        switch newTarget.kind {
        case .hls(let stream):
            webQualities = []
            webURL = nil
            // Тот же URL: плеер не пересоздастся и `onReady` не придёт, поэтому
            // не оставляем экран в вечной загрузке (выбор текущей серии в шите).
            let isSameStream = nativeStreamURL == stream
            nativeStreamURL = stream
            if isSameStream {
                handleNativePlayerReady()
            } else {
                Task { await loadQualities(for: stream, variants: newTarget.variants) }
            }
        case .web(let web):
            // Качества нативного потока к HTML-плееру не относятся.
            qualities = []
            selectedQuality = nil
            nativeStreamURL = nil
            webURL = web
            webReloadToken = UUID()
            prepareWebQuality(for: web)
            // Новая страница получает собственные 20 секунд до ошибки.
            Task { await watchLoadTimeout() }
        case .youtube:
            nativeStreamURL = nil
            webURL = nil
            webReloadToken = UUID()
            fail(.playbackUnavailable, detail: "Эта серия доступна только во внешнем плеере")
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
                closePlayer()
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

    /// Нативный поток: интерфейс рисует собственный оверлей, навбар не нужен.
    /// Для web-плеера (Kodik через прокси, YouTube) оставляем навбар: там свои контролы.
    private var usesCustomPlayerChrome: Bool {
        if case .failed = phase { return false }
        if nativeStreamURL != nil { return true }
        if case .hls = target.kind { return true }
        return false
    }

    /// Кнопка списка серий в навбаре: нужна только web-плееру (у нативного
    /// списком управляет оверлей контролов) и только когда известен источник.
    private var showsWebEpisodeListButton: Bool {
        guard releaseId != nil, typeId != nil, sourceId != nil else { return false }
        if case .failed = phase { return false }
        return !usesCustomPlayerChrome
    }

    private var closeButton: some View {
        Button {
            closePlayer()
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
            // У нативного плеера свой слой загрузки с крестиком (`loadingTopBar`
            // в `nativePlayer`) — второй полноэкранный слой перекрыл бы его.
            if !usesCustomPlayerChrome {
                PlayerLoadingView(providerName: target.providerName)
            }
        case .ready:
            // У нативного плеера кнопка «Следующая серия» живёт в оверлее
            // контролов. HTML-плееру оверлей не рисуется, поэтому для него
            // оставляем отдельную кнопку поверх видео.
            if !usesCustomPlayerChrome, controlsVisible {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        nextEpisodeButton
                    }
                }
            }
        case .failed(let error, let detail):
            PlayerErrorView(
                message: error.errorDescription ?? "Воспроизведение недоступно",
                detail: detail,
                onOpenInSafari: openInSafari,
                onClose: { closePlayer() }
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
            await loadQualities(for: url, variants: target.variants)
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
                    // Резолвер мог принести готовый список качеств — сохраняем его
                    // в цель: `loadQualities` построит меню без master-плейлиста.
                    target = resolved
                    nativeStreamURL = streamURL
                    // Нативный поток: меню качества Kodik больше не нужно.
                    webQualities = []
                    webURL = nil
                    phase = .loading
                    await loadQualities(for: streamURL, variants: resolved.variants)
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

    /// Собирает список качеств для прямого потока.
    ///
    /// Приоритет — варианты, которые сервер/резолвер уже принёс в
    /// `target.variants` (`PlaybackVariant`): меню строится из них без сети
    /// (так приходят AniLibria/RuTube/AnixPlayer/Kodik). Текущее качество
    /// выделяется по совпадению URL. Если готовых вариантов нет — разбираем
    /// master-плейлист, как раньше.
    private func loadQualities(for url: URL, variants serverVariants: [PlaybackVariant]? = nil) async {
        let serverVariants = serverVariants ?? target.variants
        if let serverVariants, !serverVariants.isEmpty {
            let mapped = serverVariants.map { variant in
                VideoQualityVariant(id: variant.quality, label: variant.quality, url: variant.url)
            }
            qualities = mapped
            selectedQuality = mapped.first(where: { $0.url == url })
                ?? VideoQualitySelector.preferred(in: mapped)
                ?? mapped.first
            return
        }
        guard url.pathExtension.lowercased() == "m3u8" else {
            qualities = []
            selectedQuality = nil
            return
        }
        do {
            let fetched = try await VideoQualitySelector.variants(from: url)
            qualities = fetched
            selectedQuality = VideoQualitySelector.preferred(in: fetched) ?? fetched.first
        } catch {
            qualities = []
            selectedQuality = nil
        }
    }

    /// Смена качества прямого потока.
    ///
    /// `AVPlayer` не меняет плейлист на лету с сохранением места, поэтому плеер
    /// пересоздаётся: новый `nativeStreamURL` меняет `.id` у `NativePlayerView`,
    /// SwiftUI создаёт новый координатор с новым `AVPlayer`. Позицию переносим
    /// через `startPositionOverride`, выбор запоминаем в `VideoQualitySelector`.
    private func selectQuality(_ variant: VideoQualityVariant) {
        guard variant.url != nativeStreamURL else {
            selectedQuality = variant
            return
        }
        selectedQuality = variant
        VideoQualitySelector.remember(variant)
        // Пересозданный плеер продолжит с текущей секунды, а не с сохранённой
        // ранее позиции и не с нуля.
        startPositionOverride = max(0, Int(playback.currentTime.rounded()))
        target = PlaybackTarget(
            kind: .hls(variant.url),
            title: target.title,
            providerName: target.providerName,
            referer: target.referer,
            variants: target.variants
        )
        nativeStreamURL = variant.url
        phase = .loading
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleControlsHide(after: Self.initialControlsHideDelay)
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

// MARK: - Контролы нативного плеера

/// Управление контролами поверх нативного видео.
///
/// `NativePlayerView` рисует только кадры, поэтому видимость контролов,
/// авто-скрытие и тапы по видео — забота экрана: одиночный тап показывает или
/// скрывает контролы (play/pause — только центральная кнопка), двойной тап по
/// левой/правой трети перематывает на ±10 секунд с короткой подсказкой.
/// Зоны тапов лежат между видео и `PlayerControlsOverlay`, поэтому кнопки
/// оверлея получают свои тапы первыми и контролы никогда не перекрываются.
private extension PlayerView {
    /// Нативный плеер плюс его SwiftUI-слой управления.
    ///
    /// Порядок слоёв задан явными `zIndex`: видео (0) → тап-зоны (1) →
    /// контролы/панель загрузки (2) → подсказки (3). Тап-зоны лежат ПОД
    /// контролами, поэтому кнопки верхней и нижней панели всегда получают свои
    /// нажатия первыми, а слой тапов не перекрывает крестик.
    func nativePlayer(url: URL) -> some View {
        ZStack {
            NativePlayerView(
                url: url,
                title: target.title,
                onFinished: {
                    handlePlaybackFinished()
                },
                startPosition: startPositionOverride ?? savedPosition,
                onProgress: nil,
                onReady: {
                    handleNativePlayerReady()
                },
                releaseId: releaseId,
                sourceId: sourceId,
                episodePosition: currentPosition,
                onPlayerLayerReady: { layer in
                    if PiPController.isSupported {
                        pipController = PiPController(playerLayer: layer)
                    }
                },
                state: playback,
                // Тапы обрабатывает сам экран, а не координатор: иначе один тап
                // и паузу ставил бы, и прятал контролы.
                handlesTap: false
            )
            // Смена качества/серии меняет URL — новый id пересоздаёт координатор
            // вместе с `AVPlayer` (старый уже непригоден для нового плейлиста).
            .id(nativeStreamURL ?? url)
            .zIndex(0)

            videoTapZones
                .zIndex(1)

            if phase == .ready {
                PlayerControlsOverlay(
                    state: playback,
                    title: currentTitle,
                    qualities: qualities,
                    selectedQuality: selectedQuality,
                    onSelectQuality: { variant in
                        selectQuality(variant)
                    },
                    onClose: {
                        closePlayer()
                    },
                    onNextEpisode: nextEpisodeAction,
                    onTogglePiP: {
                        togglePiP()
                    },
                    showPiP: PiPController.isSupported,
                    controlsVisible: controlsVisible,
                    onShowEpisodes: {
                        showsEpisodes = true
                    },
                    hasNextEpisode: nextEpisode != nil,
                    showsCloseAndTitle: false
                )
                .zIndex(2)
            } else if phase == .loading {
                // Пока видео грузится, полный оверлей бесполезен (нет длительности
                // и готового плеера), но крестик нужен: без него из загрузки не
                // выйти — раньше здесь не было вообще ничего, и пользователь
                // оставался с чёрным экраном.
                loadingTopBar
                    .zIndex(2)
            }

            skipHintOverlay
                .zIndex(3)

            // Крестик + название всегда сверху: авто-скрытие контролов их не
            // трогает, поэтому выход из плеера работает одним нажатием в любой
            // момент (жалоба «крестик не работает»).
            persistentTopChrome
                .zIndex(4)
        }
    }

    /// Постоянная верхняя строка нативного плеера: закрыть и название серии.
    var persistentTopChrome: some View {
        VStack {
            HStack(spacing: 8) {
                Button {
                    closePlayer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.35), in: Circle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть плеер")
                .accessibilityIdentifier("player-close")

                Text(currentTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Минимальная верхняя панель на время загрузки: закрыть и название серии.
    ///
    /// Явный слой над видео и тап-зонами (`zIndex`) — крестик нажимается
    /// с первого тапа в любой фазе, включая `.loading`.
    var loadingTopBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Крестик рисует постоянный `persistentTopChrome` поверх всего.
                Text(currentTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Подложка декоративная: тапы по видео под панелью должны проходить дальше.
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear],
                           startPoint: .top,
                           endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    /// Первый кадр нативного потока: снимаем панель загрузки и запускаем
    /// авто-скрытие контролов (после смены качества/серии — заново).
    func handleNativePlayerReady() {
        startPositionOverride = nil
        phase = .ready
        guard controlsVisible else { return }
        let delay = hasAutoHiddenControls ? Self.controlsHideDelay : Self.initialControlsHideDelay
        scheduleControlsHide(after: delay)
    }

    var videoTapZones: some View {
        HStack(spacing: 0) {
            tapZone(hint: "−10 с", skipBy: -Self.skipStep)
            tapZone(hint: nil, skipBy: nil)
            tapZone(hint: "+10 с", skipBy: Self.skipStep)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Верхняя и нижняя панели контролов остаются вне тап-зон: даже когда
        // оверлей скрыт, тап по его будущей полосе не переключает контролы.
        .padding(.vertical, 80)
    }

    /// Одна треть видео: слева/справа двойной тап перематывает, в центре — нет.
    func tapZone(hint: String?, skipBy seconds: Double?) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                guard let seconds, let hint else { return }
                skip(by: seconds, hint: hint)
            }
            .onTapGesture(count: 1) {
                toggleControls()
            }
    }

    /// Двойной тап: перемотка и короткая подсказка поверх видео.
    func skip(by seconds: Double, hint: String) {
        playback.skip(by: seconds)
        showSkipHint(hint)
        if controlsVisible {
            scheduleControlsHide(after: Self.controlsHideDelay)
        }
    }

    func showSkipHint(_ text: String) {
        skipHintTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { skipHint = text }
        skipHintTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.skipHintDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { skipHint = nil }
        }
    }

    @ViewBuilder
    var skipHintOverlay: some View {
        if let skipHint {
            Text(skipHint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.72), in: Capsule())
                .accessibilityIdentifier("player-skip-hint")
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Показать/скрыть контролы тапом по видео.
    func toggleControls() {
        if controlsVisible {
            hideControls()
        } else {
            revealControls()
        }
    }

    func revealControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleControlsHide(after: Self.controlsHideDelay)
    }

    func hideControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
    }

    /// Авто-скрытие контролов: 6 секунд при открытии, 4 — после взаимодействия.
    ///
    /// Прячем, только если видео действительно играет: на паузе контролы
    /// остаются на экране. Каждый новый вызов отменяет предыдущий таймер.
    func scheduleControlsHide(after delay: UInt64) {
        // В отладочном режиме держим контролы на экране: так CI снимает
        // скриншот интерфейса плеера, и его не нужно «успевать» поймать.
        guard !forceControlsVisible else { return }
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            controlsHideTask = nil
            guard playback.isPlaying else { return }
            hasAutoHiddenControls = true
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// Действие «следующая серия» для оверлея: `nil`, когда следующей нет.
    var nextEpisodeAction: (() -> Void)? {
        guard let next = nextEpisode else { return nil }
        return { playNext(next) }
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
