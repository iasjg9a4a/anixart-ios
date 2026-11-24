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
/// Пока плеер не сообщил о готовности (`onLoaded`/`onReady`), на экране висит
/// спиннер оверлея контролов. Если за 30 секунд плеер не ответил (или WKWebView
/// сообщил об ошибке), вместо видео показывается ошибка с кнопкой «Открыть
/// в Safari»: так пользователь не остаётся с чёрным экраном и вечной загрузкой.
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
    /// Ссылку следующей серии уже подогрели (`EpisodePlaybackService.prefetch`).
    /// Сбрасывается на каждой новой серии.
    @State private var hasPrefetchedNextStream = false
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
    /// Сторожевой таймер загрузки: `.loading` дольше 30 секунд — ошибка, а не
    /// вечный спиннер. Перезапускается при старте серии/смене качества,
    /// отменяется при `ready`/`failed`.
    @State private var loadTimeoutTask: Task<Void, Never>?
    /// Резолв текущей серии (`EpisodePlaybackService.resolve`). Новая смена серии
    /// отменяет прошлую, чтобы поздний ответ не перебил только что выбранную серию.
    @State private var playbackTask: Task<Void, Never>?
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

    /// Сколько ждём готовности плеера, прежде чем показать ошибку.
    ///
    /// 30 секунд — верхняя граница и для резолва серии (API + нативный резолвер),
    /// и для буферизации: Kodik/AniLibria на медленной сети отвечают не мгновенно,
    /// но «вечную загрузку» пользователь видеть не должен.
    private static let playbackTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000

    /// Первый показ контролов: 6 секунд. CI-скриншот `14-player-controls.png`
    /// снимается через 5 секунд после запуска — контролы должны быть в кадре.
    private static let initialControlsHideDelay: UInt64 = 6 * 1_000_000_000

    /// Авто-скрытие контролов после взаимодействия с плеером.
    private static let controlsHideDelay: UInt64 = 4 * 1_000_000_000

    /// Шаг перемотки двойным тапом по левой/правой трети видео.
    private static let skipStep: Double = 10

    /// За сколько секунд до конца серии подогревать следующую.
    ///
    /// Переход на следующую серию стоит двух сетевых шагов (`episode/target` +
    /// нативный резолвер), то есть от половины секунды до нескольких секунд спиннера.
    /// Подписанная ссылка живёт недолго, поэтому резолвим не сразу, а на
    /// последних минутах — к нажатию кнопки цель уже лежит в
    /// `EpisodeResolutionCache` (его TTL 5 минут покрывает это с запасом).
    private static let nextEpisodePrefetchLead: Double = 150

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
            // Геометрия safe area нужна для поправки центрирования: видео
            // полноэкранное и центрируется по экрану, а оверлей контролов
            // живёт в safe area. Без поправки центр интерфейса (play/pause,
            // спиннер загрузки, подсказки) смещён относительно центра видео
            // на разницу инсетов — в ландшафте с вырезом это десятки пунктов
            // вбок (жалоба: «положение интерфейса осталось таким же»).
            GeometryReader { geometry in
                let insets = geometry.safeAreaInsets
                // Перевод центра safe area в центр экрана: полосы контролов
                // остаются в safe area, а центрированные элементы совпадают
                // с центром видео.
                let centerOffset = CGSize(
                    width: (insets.trailing - insets.leading) / 2,
                    height: (insets.bottom - insets.top) / 2
                )

                ZStack {
                    // Слои экрана: фон → видео → оверлей контролов/ошибки → подсказки.
                    Color.black.ignoresSafeArea()
                        .zIndex(0)

                    player
                        // Видео должно занимать весь экран и центрироваться: без этого
                        // safe area/navbar оставляли смещённую область и картинка
                        // «прилипала» к одному краю.
                        .ignoresSafeArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(1)

                    // Визуальной шапки с названием у плеера больше нет (интерфейс —
                    // в оверлее контролов, «крестик без названия»). Но серия должна
                    // оставаться доступной VoiceOver'у и UI-тесту
                    // (`testPlayerOpensForEpisode` ищет staticText «1 серия»):
                    // невидимый (1×1 pt) текстовый элемент в дереве доступности.
                    Text(currentTitle)
                        .font(.caption2)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .accessibilityHidden(false)
                        .zIndex(1)

                    // Интерфейс экрана целиком в оверлее контролов (крестик, качество,
                    // скорость, play/pause, перемотка, серии, PiP). Отдельной постоянной
                    // шапки и своего крестика у `PlayerView` больше нет.
                    overlay(centerOffset: centerOffset)
                        .zIndex(2)

                    // Крестик поверх всего: появляется/прячется вместе с контролами,
                    // но лежит выше оверлея, поэтому нажатие всегда доходит до кнопки.
                    if isNativePlayback {
                        closeChrome
                            .zIndex(4)
                    }

                    skipHintOverlay
                        .offset(centerOffset)
                        .zIndex(3)
                }
            }
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            // У нативного видео есть свои контролы (закрыть, качество, скорость, PiP):
            // системный навбар дублировал бы крестик и заголовок двумя строками.
            .toolbar(usesCustomPlayerChrome ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                // У web-плеера крестик в навбаре (у нативного — свой слой closeChrome).
                if !usesCustomPlayerChrome {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            closePlayer()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Закрыть плеер")
                        .accessibilityIdentifier("player-close-nav")
                    }
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
                // У web-плеера список серий дополнительно доступен из навбара.
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
            // Пока открыт плеер, экран не должен гаснуть и блокироваться:
            // видео само по себе таймер простоя не отключает, и серию
            // приходилось «будить» тапом.
            setIdleTimer(disabled: true)
        }
        .onDisappear {
            controlsHideTask?.cancel()
            skipHintTask?.cancel()
            loadTimeoutTask?.cancel()
            playbackTask?.cancel()
            setIdleTimer(disabled: false)
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
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        playbackTask?.cancel()
        playbackTask = nil
        // Владелец презентации может передать явный обработчик — он надёжнее
        // `dismiss()` внутри `NavigationStack` (был баг: крестик не закрывал плеер).
        if let onCloseExplicit {
            onCloseExplicit()
        } else {
            dismiss()
        }
    }

    /// Крестик поверх всех слоёв плеера.
    ///
    /// Показывается и прячется вместе с контролами (`controlsVisible`), поэтому
    /// «активен только когда экран потрогали». Отдельный слой выше оверлея нужен
    /// из-за бага: тап по кнопке внутри автоскрываемого оверлея не всегда доходил.
    var closeChrome: some View {
        VStack {
            HStack {
                Button {
                    closePlayer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть плеер")
                .accessibilityIdentifier("player-close")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .allowsHitTesting(controlsVisible)
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

    /// Подогревает ссылку следующей серии на последних минутах текущей.
    ///
    /// Вызывается из `onProgress` нативного плеера (раз в 5 секунд). Резолв
    /// идёт в фоне через `EpisodePlaybackService.prefetch(...)`, поэтому
    /// нажатие «Следующая серия» потом не ждёт ни `episode/target`, ни
    /// нативный резолвер провайдера. Подогреваем один раз на серию: повторный
    /// вызов всё равно отсекается кэшем, но и лишних задач не плодим.
    ///
    /// Почему не сразу при старте серии: подписанная ссылка истекает, и
    /// подогретая за 20 минут до нажатия цель была бы бесполезной.
    private func prefetchNextStreamIfNeeded(at seconds: Int) {
        guard !hasPrefetchedNextStream, let next = nextEpisode else { return }
        let duration = playback.duration
        guard duration > 0, duration - Double(seconds) <= Self.nextEpisodePrefetchLead else { return }
        hasPrefetchedNextStream = true
        EpisodePlaybackService.prefetch(
            releaseId: next.releaseId,
            sourceId: next.sourceId,
            position: next.position,
            title: next.title,
            typeId: next.typeId ?? typeId
        )
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
    /// свежий `episode/target` запрашивается в момент перехода, а не берётся
    /// из списка серий. Резолв идёт ровно тем же путём, что и старт с релиза, —
    /// `EpisodePlaybackService.resolve(...)`: у Kodik это нативный HLS через
    /// `ftor` (обход web-прокси и его «Error code: ds»), у Sibnet/AniLibria/
    /// RuTube/AnixPlayer — их нативные резолверы. Старый упрощённый путь
    /// (`NextEpisodeService.resolvedTarget` + `PlaybackResolver`) оставлял Kodik
    /// на web-прокси, а нативные источники — на `.web`-цели, которую `AVPlayer`
    /// бесконечно грузил.
    ///
    /// Пока идёт резолв — `.loading`; сторожевой таймер (`scheduleLoadTimeout`)
    /// не даёт залипнуть в этой фазе дольше 30 секунд.
    /// - Parameter ignoringCache: `true` — не брать подогретую цель из
    ///   `EpisodeResolutionCache`, а резолвить заново (кнопка «Повторить»).
    private func startPlayback(position newPosition: Int,
                               sourceId newSourceId: Int?,
                               title newTitle: String,
                               ignoringCache: Bool = false) {
        guard let releaseId, let sourceId = newSourceId ?? sourceId else {
            fail(.playbackUnavailable, detail: "Не удалось определить источник серии")
            return
        }
        nextEpisode = nil
        hasPrefetchedNextStream = false
        phase = .loading
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleLoadTimeout()
        playbackTask?.cancel()
        playbackTask = Task { @MainActor in
            do {
                let resolved = try await EpisodePlaybackService.resolve(
                    releaseId: releaseId,
                    sourceId: sourceId,
                    position: newPosition,
                    title: newTitle,
                    typeId: typeId,
                    ignoringCache: ignoringCache
                )
                // Пока шёл резолв, серию могли сменить (новая задача отменила эту)
                // или таймер уже показал ошибку — поздний ответ не должен стартовать.
                guard !Task.isCancelled, phase == .loading else { return }
                beginPlayback(resolved.target, position: newPosition, title: newTitle)
            } catch {
                guard !Task.isCancelled, phase == .loading else { return }
                fail(Self.playbackError(from: error), detail: Self.playbackDetail(from: error))
            }
        }
    }

    /// Ошибка резолва для `PlayerPhase.failed`: `PlaybackError` показываем как есть,
    /// остальные (сеть/API) — общей фразой, а текст причины уходит в подпись.
    private static func playbackError(from error: Error) -> PlaybackError {
        if let playbackError = error as? PlaybackError { return playbackError }
        return .playbackUnavailable
    }

    private static func playbackDetail(from error: Error) -> String? {
        guard !(error is PlaybackError) else { return nil }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
        hasPrefetchedNextStream = false
        startPositionOverride = nil
        currentPosition = newPosition
        currentTitle = newTitle
        target = newTarget
        phase = .loading
        // Сторожевой таймер не перезапускаем: 30 секунд отсчитываются от нажатия
        // «следующая/выбрать серию» (`startPlayback`), включая время резолва —
        // иначе медленный резолв растягивал бы ожидание далеко за 30 секунд.
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
            // Сторожевой таймер уже запущен в `startPlayback` (30 секунд на весь
            // переход: резолв + загрузка страницы), заново его не перезапускаем.
        case .youtube:
            nativeStreamURL = nil
            webURL = nil
            webReloadToken = UUID()
            fail(.playbackUnavailable, detail: "Эта серия доступна только во внешнем плеере")
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
                handleWebPlayerReady()
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

    /// Играем нативным AVPlayer (HLS/mp4): только в этом случае рисуем свои
    /// контролы. У web-плеера (WKWebView) своя панель провайдера — наш оверлей
    /// поверх давал «два интерфейса в одном месте» (жалоба по AniLibria).
    private var isNativePlayback: Bool {
        if case .failed = phase { return false }
        if nativeStreamURL != nil { return true }
        if case .hls = target.kind { return true }
        return false
    }

    /// Нативный поток: интерфейс рисует оверлей контролов, навбар не нужен.
    /// Для web-плеера (запасной путь Kodik через прокси, YouTube) навбар остаётся:
    /// в нём меню качества и список серий, а оверлей контролов не работает с
    /// `WKWebView` (у него нет `AVPlayer`).
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

    @ViewBuilder
    private func overlay(centerOffset: CGSize) -> some View {
        switch phase {
        case .failed(let error, let detail):
            // Ошибка вместо контролов: спиннер и кнопки на сломанном плеере
            // бесполезны, а «Закрыть»/«Safari» в `PlayerErrorView` дают выход.
            PlayerErrorView(
                message: error.errorDescription ?? "Воспроизведение недоступно",
                detail: detail,
                onRetry: { retryPlayback() },
                onOpenInSafari: openInSafari,
                onClose: { closePlayer() }
            )
            .offset(centerOffset)
        case .loading, .ready:
            if !isNativePlayback {
                // Web-плеер: интерфейс — страница провайдера в WKWebView.
                // Свои контролы поверх не рисуем (было «два интерфейса»),
                // только спиннер загрузки и кнопку следующей серии.
                if phase == .loading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Загрузка \(target.providerName)…")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.35))
                    .allowsHitTesting(false)
                    .offset(centerOffset)
                } else {
                    webReadyOverlay
                }
            } else {
            // Единственный интерфейс нативного экрана: крестик, качество,
            // скорость, PiP, play/pause, перемотка, «следующая серия», серии.
            // В `.loading` оверлей рисует спиннер и прячет нижнюю панель.
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
                isLoading: phase == .loading,
                centerOffset: centerOffset
            )
            }
        }
    }

    /// Поверх web-плеера: только «следующая серия» (панель провайдера — его).
    @ViewBuilder
    private var webReadyOverlay: some View {
        if nextEpisode != nil {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        nextEpisodeAction?()
                    } label: {
                        Label("Следующая серия", systemImage: "forward.end.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.65), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player-next-episode")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Подготовка источника

    /// Пытается получить нативный HLS у провайдеров, которые отдают HTML-страницу
    /// (Sibnet/AniLibria/RuTube/AnixPlayer). Если не удалось — остаёмся на WebView.
    ///
    /// Стартовая цель обычно уже нативная: `ReleaseView` и отладочный маршрут
    /// резолвят Kodik/Kodik-подобные через `EpisodePlaybackService`/`KodikDirectResolver`.
    /// Здесь разбирается только web-цель, которая всё-таки дошла до экрана.
    /// Kodik остаётся в WebView лишь как запасной путь (качество у него берётся
    /// из пути ссылки — меню готовит `prepareWebQuality(for:)`).
    private func preparePlayback() async {
        // Страховка от вечной загрузки для любого стартового пути.
        scheduleLoadTimeout()
        switch target.kind {
        case .hls(let url):
            nativeStreamURL = url
            await loadQualities(for: url, variants: target.variants)
        case .youtube:
            fail(.playbackUnavailable, detail: "Эта серия доступна только во внешнем плеере")
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
                    // Kodik и неизвестные плееры играем в WebView: сторожевой
                    // таймер уже запущен выше и покажет ошибку, если страница не встанет.
                    return
                }
                if case .hls(let streamURL) = resolved.kind {
                    // Резолвер мог принести готовый список качеств — сохраняем его
                    // в цель: `loadQualities` построит меню без master-плейлиста.
                    target = resolved
                    nativeStreamURL = streamURL
                    // Нативный поток: меню качества web-плеера больше не нужно.
                    webQualities = []
                    webURL = nil
                    phase = .loading
                    // Новый (нативный) путь получает собственные 30 секунд.
                    scheduleLoadTimeout()
                    await loadQualities(for: streamURL, variants: resolved.variants)
                    return
                }
            } catch {
                // HTML-плеер может сработать — молча откатываемся на WebView.
            }
            // Web-плеер уже под сторожем: `scheduleLoadTimeout` вызван в начале.
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
            variants: target.variants,
            httpHeaders: target.httpHeaders
        )
        nativeStreamURL = variant.url
        phase = .loading
        // Новый поток получает собственные 30 секунд до ошибки.
        scheduleLoadTimeout()
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
        // Новая страница получает собственные 30 секунд до ошибки.
        scheduleLoadTimeout()
    }

    // MARK: - Загрузка и ошибки

    /// Сторожевой таймер загрузки: если через 30 секунд после старта серии
    /// (или смены качества) плеер так и не перешёл в `.ready`, показываем ошибку
    /// вместо бесконечного спиннера.
    ///
    /// Запускается на каждый старт/смену серии/качества и отменяется в
    /// `handleNativePlayerReady`/`handleWebPlayerReady` и в `fail(...)`, поэтому
    /// старый таймер никогда не «убивает» уже готовый новый плеер.
    private func scheduleLoadTimeout() {
        cancelLoadTimeout()
        loadTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.playbackTimeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            loadTimeoutTask = nil
            guard phase == .loading else { return }
            fail(.playbackUnavailable, detail: "Плеер не ответил за 30 секунд")
        }
    }

    /// Снимает сторожевой таймер: плеер готов или показ уже завершился.
    private func cancelLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
    }

    private func fail(_ error: PlaybackError, detail: String? = nil) {
        cancelLoadTimeout()
        phase = .failed(error, detail: detail)
    }

    /// «Повторить» на экране ошибки.
    ///
    /// Чаще всего серия не пошла из-за сети или истёкшей подписанной ссылки,
    /// поэтому пробуем ту же серию заново и **в обход кэша** — иначе повтор
    /// взял бы ту же нерабочую цель. Если серия неизвестна (отладочный маршрут
    /// с готовой ссылкой), перезапускаем исходный путь подготовки.
    private func retryPlayback() {
        if let position = currentPosition, releaseId != nil, sourceId != nil {
            startPlayback(position: position,
                          sourceId: sourceId,
                          title: currentTitle,
                          ignoringCache: true)
            return
        }
        phase = .loading
        webReloadToken = UUID()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        playbackTask?.cancel()
        playbackTask = Task { @MainActor in
            await preparePlayback()
        }
    }

    /// Не давать экрану гаснуть, пока открыт плеер.
    ///
    /// `AVPlayer` сам таймер простоя не трогает: без этого экран тускнел и
    /// блокировался посреди серии (особенно заметно на паузе и в web-плеере).
    private func setIdleTimer(disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
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
    /// Нативный плеер плюс тап-зоны экрана.
    ///
    /// Интерфейс (крестик, качество, скорость, play/pause, перемотка, серии)
    /// рисует единый оверлей `PlayerControlsOverlay` в `body` — здесь только
    /// видео и прозрачные тап-зоны. Тап-зоны лежат ПОД оверлеем, поэтому кнопки
    /// получают свои нажатия первыми, а одиночный/двойной тап по пустому видео
    /// доходит до экрана и показывает/скрывает контролы либо перематывает.
    func nativePlayer(url: URL) -> some View {
        ZStack {
            NativePlayerView(
                url: url,
                title: currentTitle,
                onFinished: {
                    handlePlaybackFinished()
                },
                startPosition: startPositionOverride ?? savedPosition,
                // Раз в 5 секунд: на последних минутах подогреваем ссылку
                // следующей серии, чтобы переход был мгновенным.
                onProgress: { seconds in
                    prefetchNextStreamIfNeeded(at: seconds)
                },
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
                handlesTap: false,
                // Кнопка «вперёд» на локскрине/наушниках = «Следующая серия».
                onRemoteNext: nextEpisodeAction,
                // `Referer`/`User-Agent` для CDN, которые их проверяют (Sibnet).
                httpHeaders: target.httpHeaders
            )
            // Смена качества/серии меняет URL — новый id пересоздаёт координатор
            // вместе с `AVPlayer` (старый уже непригоден для нового плейлиста).
            .id(nativeStreamURL ?? url)
            .zIndex(0)

            videoTapZones
                .zIndex(1)
        }
    }

    /// Первый кадр нативного потока: снимаем сторожевой таймер загрузки и
    /// запускаем авто-скрытие контролов (после смены качества/серии — заново).
    func handleNativePlayerReady() {
        cancelLoadTimeout()
        startPositionOverride = nil
        phase = .ready
        guard controlsVisible else { return }
        let delay = hasAutoHiddenControls ? Self.controlsHideDelay : Self.initialControlsHideDelay
        scheduleControlsHide(after: delay)
    }

    /// Web-плеер сообщил, что страница загружена: снимаем сторожевой таймер.
    func handleWebPlayerReady() {
        cancelLoadTimeout()
        phase = .ready
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

/// Экран ошибки: текст `PlaybackError`, техническая причина и выход в Safari.

private struct PlayerErrorView: View {
    let message: String
    let detail: String?
    /// Повторить ту же серию (свежий резолв, минуя кэш).
    let onRetry: () -> Void
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

            // «Повторить» — первая кнопка: чаще всего серия не пошла из-за
            // сети или истёкшей ссылки, и вторая попытка её поднимает.
            Button(action: onRetry) {
                Text("Повторить")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Theme.accent, in: Capsule())
            }
            .accessibilityIdentifier("player-retry")

            Button(action: onOpenInSafari) {
                Text("Открыть в Safari")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Theme.surfaceHigh, in: Capsule())
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
