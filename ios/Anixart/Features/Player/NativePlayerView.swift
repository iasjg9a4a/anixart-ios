import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - Нативный плеер

/// Плеер прямых потоков: HLS (RuTube, AnixPlayer) и обычные `mp4`/`mov`.
///
/// Вместо `VideoPlayer` кадры рисует `AVPlayerLayer`: нужны сохранение позиции,
/// отметка просмотра и место под свои кнопки (AirPlay, PiP, «следующая серия»).
/// Тап по видео — play/pause, спиннер показывает буферизацию, прерывания
/// аудиосессии ставят видео на паузу.
///
/// Прогресс уходит наружу двумя путями: `onProgress` (раз в 5 секунд — для UI)
/// и `PlaybackProgress.shared` (если известны идентификаторы серии). По концу
/// видео серия отмечается просмотренной, а локальная позиция сбрасывается в 0.
///
/// PiP: слой отдаётся через `onPlayerLayerReady`, из него экран собирает
/// `PiPController`. PiP и фон требуют `UIBackgroundModes = audio` в Info.plist.
///
/// Контролы рисует SwiftUI-оверлей экрана, а этому вью нужен мост к `AVPlayer`:
/// передайте `state`, и координатор начнёт публиковать в него состояние
/// (время/длительность/play/pause/буферизацию/скорость) и принимать команды.
/// Без `state` поведение прежнее — в том числе тап по видео как play/pause.
struct NativePlayerView: UIViewRepresentable {
    /// Прямая ссылка на поток (`.m3u8`, `.mp4`, `.mov`).
    let url: URL
    /// Название серии; используется как `accessibilityLabel` слоя.
    let title: String
    /// Вызывается, когда видео доиграло до конца.
    var onFinished: (() -> Void)?
    /// С какой секунды начинать. `0` — с начала.
    var startPosition: Int = 0
    /// Текущая позиция в секундах, раз в 5 секунд.
    var onProgress: ((Int) -> Void)?
    /// Один раз, когда видео реально начало играть: по нему `PlayerView`
    /// убирает свой оверлей загрузки.
    var onReady: (() -> Void)?
    /// Идентификаторы серии для `PlaybackProgress`; без них прогресс не пишется.
    var releaseId: Int?
    var sourceId: Int?
    var episodePosition: Int?
    /// Отдаёт созданный `AVPlayerLayer` — по нему экран строит `PiPController`.
    var onPlayerLayerReady: ((AVPlayerLayer) -> Void)?
    /// Мост к SwiftUI-оверлею контролов: сюда публикуется состояние плеера,
    /// отсюда приходят команды (play/pause, перемотка, скорость). `nil` — режим
    /// обратной совместимости, всё работает как раньше.
    var state: NativePlaybackState? = nil
    /// Обрабатывать ли тап по видео внутри вьюхи (play/pause при `state`).
    /// `false` — тап-жесты забирает SwiftUI-оверлей экрана; это единственный
    /// способ не срабатывать дважды, если оверлей накрывает плеер своими зонами.
    var handlesTap: Bool = true

    /// Переход к следующей серии по кнопке «вперёд» на локскрине/наушниках.
    ///
    /// `nil` — следующей серии нет (или экран её ещё не нашёл), и системная
    /// кнопка «следующий трек» выключена. Содержимое экрана выбирает
    /// `PlayerView`: это то же действие, что у кнопки «Следующая серия».
    var onRemoteNext: (() -> Void)?

    /// HTTP-заголовки для запросов к потоку (`Referer`/`User-Agent`).
    ///
    /// `AVPlayer` не умеет ставить их публичным API, поэтому используется ключ
    /// `AVURLAssetHTTPHeaderFieldsKey` у `AVURLAsset` (тем же путём ходят
    /// сторонние плееры). Нужно источникам, которые проверяют Referer
    /// (например, Sibnet); `nil` — обычный поток без заголовков.
    var httpHeaders: [String: String]?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        context.coordinator.start()
        return context.coordinator.containerView
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }
}

// MARK: - UIView плеера

/// UIView с `AVPlayerLayer`.
///
/// Слои живут саблеером контейнера, frame обновляется в `layoutSubviews`: размер
/// задаёт SwiftUI (в том числе при повороте), видео вписано по `.resizeAspect`.
final class PlayerContainerView: UIView {
    let playerLayer: AVPlayerLayer

    /// Тап по видео — переключение play/pause.
    var onTap: (() -> Void)?

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        super.init(frame: .zero)

        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button

        layer.addSublayer(playerLayer)

        // Своего индикатора загрузки у контейнера нет: единственный спиннер
        // рисует SwiftUI-оверлей контролов (`player-buffering`). Системный
        // белый спиннер дублировал его — было видно две иконки загрузки
        // (белая от плеера и оранжевая от интерфейса), жалоба по AniLibria.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onTap?()
    }
}

// MARK: - Координатор

extension NativePlayerView {
    /// Владеет `AVPlayer`, слоем и подписками; живёт столько же, сколько UIView.
    ///
    /// `@MainActor`: UIKit и `AVPlayer` в новых SDK помечены `@MainActor`, а блоки
    /// таймера/уведомлений приходят из nonisolated-замыканий — переход на актор
    /// указан в них явно.
    @MainActor
    final class Coordinator {
        let containerView: PlayerContainerView
        let player: AVPlayer

        private var parent: NativePlayerView
        private var progressTimer: Timer?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var interruptionObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var bufferEmptyObservation: NSKeyValueObservation?
        private var likelyToKeepUpObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var hasStarted = false
        private var hasFinished = false
        private var hasReportedReady = false
        private var wasPlayingBeforeInterruption = false
        /// Мост, реально подключённый к `player` (может отличаться от `parent.state`
        /// во время пересоздания вьюхи).
        private var attachedState: NativePlaybackState?

        /// Карточка «сейчас играет» и внешние кнопки (локскрин, наушники,
        /// пункт управления). Живёт столько же, сколько координатор: карточку
        /// снимает `stop()`.
        private let nowPlaying = NowPlayingController()

        init(parent: NativePlayerView) {
            self.parent = parent
            let player = AVPlayer()
            self.player = player
            self.containerView = PlayerContainerView(player: player)
        }

        // MARK: Жизненный цикл

        func start() {
            guard !hasStarted else { return }
            hasStarted = true

            configureTapHandling()
            containerView.accessibilityLabel = parent.title

            // Мост подключаем до первых событий плеера: KVO `AVPlayerItem.status`
            // и периодический наблюдатель начинают публиковать состояние сразу.
            syncState()
            activateAudioSession()
            activateNowPlaying()
            loadItem()
            observePlayback()
            observeAudioInterruptions()
            startProgressTimer()
            player.play()
            reportPlayerLayer()
        }

        func update(parent: NativePlayerView) {
            let urlChanged = parent.url != self.parent.url
            let tapChanged = parent.handlesTap != self.parent.handlesTap
            self.parent = parent
            containerView.accessibilityLabel = parent.title
            if tapChanged {
                configureTapHandling()
            }
            syncState()
            if urlChanged {
                reloadItem()
            }
        }

        func stop() {
            stopProgressTimer()
            removePlaybackObservers()
            removeItemObservers()
            removeInterruptionObserver()
            // Карточку снимаем до освобождения плеера: иначе на локскрине
            // остаётся «призрак» серии, которую уже никто не играет.
            nowPlaying.deactivate()
            detachState()

            if !hasFinished, let seconds = currentSeconds(), seconds > 0 {
                // Последние секунды иначе потеряются: таймер мог не успеть.
                // Нулевую позицию не сохраняем, чтобы не стереть прошлый прогресс.
                parent.onProgress?(seconds)
                reportHistory(seconds)
            }

            player.pause()
            player.replaceCurrentItem(with: nil)
            deactivateAudioSession()
        }

        deinit {
            progressTimer?.invalidate()
            if let timeObserver = timeObserver {
                player.removeTimeObserver(timeObserver)
            }
        }

        // MARK: Мост к SwiftUI-оверлею

        /// Подключает `NativePlaybackState` к нашему `AVPlayer`.
        ///
        /// SwiftUI может пересоздать вьюху, не дождавшись `dismantle` старой,
        /// поэтому подключение идемпотентно: состояние, оставшееся от прошлого
        /// плеера, сбрасываем и переподключаем к текущему.
        private func syncState() {
            let desired = parent.state
            var changed = false
            if let current = attachedState, current !== desired {
                if current.player === player {
                    current.detach()
                }
                attachedState = nil
                changed = true
            }
            guard let state = desired else { return }
            if state.player !== player {
                if state.player != nil {
                    state.detach()
                }
                state.attach(player: player)
                changed = true
            }
            attachedState = state
            // Публикуем только при (пере)подключении и на следующем витке главного
            // актора: иначе каждый `updateUIView` порождал бы новое изменение
            // @Published и SwiftUI перерисовывал бы экран бесконечно (а менять
            // состояние прямо из updateUIView не стоит).
            if changed {
                Task { @MainActor [weak self] in
                    self?.publishPlaybackState()
                }
            }
        }

        /// Отключает мост при разборке вьюхи. Только если он всё ещё подключён
        /// к нашему плееру: новый координатор мог уже забрать его себе.
        private func detachState() {
            guard let state = attachedState else { return }
            if state.player === player {
                state.detach()
            }
            attachedState = nil
        }

        /// Публикует состояние в мост: время, длительность, play/pause,
        /// буферизацию и скорость. Вызывается периодическим наблюдателем (0.25 с)
        /// и по KVO — повторные вызовы безопасны, `update` гасит NaN и не трогает
        /// время, пока пользователь тащит ползунок (`state.isSeeking`).
        private func publishPlaybackState() {
            guard let state = attachedState, state.player === player else { return }
            let item = player.currentItem
            let status = item?.status ?? .unknown
            state.update(
                time: player.currentTime().seconds,
                duration: item?.duration.seconds ?? 0,
                isPlaying: isPlaying,
                isBuffering: isWaitingToPlay || status == .unknown,
                rate: player.rate
            )
            updateNowPlaying()
        }

        /// KVO состояния буфера: `timeControlStatus` не всегда сразу становится
        /// `.waitingToPlayAtSpecifiedRate`, когда буфер опустел, а периодический
        /// наблюдатель молчит, пока время стоит. Публикуем буферизацию сразу.
        private func publishBufferingState() {
            guard let state = attachedState, state.player === player,
                  let item = player.currentItem else { return }
            let isStarved = isPlaying && (item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp)
            state.update(
                time: player.currentTime().seconds,
                duration: item.duration.seconds,
                isPlaying: isPlaying,
                isBuffering: isWaitingToPlay || item.status == .unknown || isStarved,
                rate: player.rate
            )
        }

        /// `AVPlayerItem.status == .readyToPlay` — единственный сигнал, что видео
        /// реально загрузилось и готово к показу (не «время пошло»). С мостом
        /// отдаём готовность сразу, чтобы экран снял оверлей загрузки на кадре.
        private func handleItemStatus(rawValue: Int) {
            guard rawValue == AVPlayerItem.Status.readyToPlay.rawValue else { return }
            guard let state = attachedState, state.player === player else { return }
            state.markReady()
            reportReadyIfNeeded()
        }

        // MARK: Экран блокировки и внешние кнопки

        /// Подписывает локскрин/наушники/пункт управления на наш плеер.
        ///
        /// Команды идут тем же путём, что и кнопки оверлея: через мост
        /// `NativePlaybackState` (а без него — прямо в `AVPlayer`), поэтому
        /// интерфейс и системная карточка всегда показывают одно и то же.
        private func activateNowPlaying() {
            nowPlaying.activate(commands: NowPlayingController.Commands(
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.togglePlayback() },
                skip: { [weak self] seconds in self?.remoteSkip(by: seconds) },
                seek: { [weak self] seconds in self?.remoteSeek(to: seconds) },
                next: { [weak self] in self?.parent.onRemoteNext?() }
            ))
        }

        /// Отдаёт системе текущее состояние серии. Частоту обновлений
        /// ограничивает сам `NowPlayingController` (локскрин сам двигает
        /// ползунок между обновлениями).
        private func updateNowPlaying() {
            nowPlaying.update(
                title: parent.title,
                isPlaying: isPlaying,
                currentTime: player.currentTime().seconds,
                duration: player.currentItem?.duration.seconds ?? 0,
                rate: attachedState?.rate ?? 1,
                hasNext: parent.onRemoteNext != nil
            )
        }

        /// ±10 секунд с локскрина/наушников.
        private func remoteSkip(by seconds: Double) {
            if let state = attachedState, state.player === player {
                state.skip(by: seconds)
                return
            }
            remoteSeek(to: player.currentTime().seconds + seconds)
        }

        /// Перетаскивание позиции на локскрине.
        private func remoteSeek(to seconds: Double) {
            if let state = attachedState, state.player === player {
                state.seek(to: seconds, precise: false)
                return
            }
            guard seconds.isFinite else { return }
            let tolerance = CMTime(seconds: 0.75, preferredTimescale: 600)
            player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                        toleranceBefore: tolerance,
                        toleranceAfter: tolerance)
        }

        /// Новый `AVPlayerItem` (смена качества/серии): сбрасываем мост, чтобы
        /// оверлей не показывал длительность и готовность прошлого видео.
        /// Скорость пользователя при этом сохраняем.
        private func resetStateForNewItem() {
            guard let state = attachedState else { return }
            let rate = state.rate
            state.detach()
            state.attach(player: player)
            state.setRate(rate)
        }

        // MARK: Загрузка

        /// `AVPlayerItem` с HTTP-заголовками, если они нужны источнику.
        ///
        /// Публичного API для `Referer`/`User-Agent` у `AVURLAsset` нет: ключ
        /// `AVURLAssetHTTPHeaderFieldsKey` — тот же недокументированный механизм,
        /// которым пользуются сторонние плееры. Заголовки уходят во все запросы
        /// ресурса (манифест, сегменты, диапазоны), поэтому Sibnet-CDN видит
        /// правильный Referer, а не «пустой» от AVFoundation.
        private func makePlayerItem(url: URL, httpHeaders: [String: String]?) -> AVPlayerItem {
            guard let httpHeaders, !httpHeaders.isEmpty else {
                return AVPlayerItem(url: url)
            }
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
            return AVPlayerItem(asset: asset)
        }

        private func loadItem() {
            let item = makePlayerItem(url: parent.url, httpHeaders: parent.httpHeaders)
            player.replaceCurrentItem(with: item)
            observeItem(item)

            if parent.startPosition > 0 {
                let position = CMTime(seconds: Double(parent.startPosition), preferredTimescale: 600)
                // Допуск ±1 с: точный seek (нулевой допуск) заставляет AVPlayer
                // докачать и декодировать от ключевого кадра — продолжение
                // просмотра и смена качества из-за этого стартуют заметно
                // дольше. Секунда на глаз незаметна.
                let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
                player.seek(to: position, toleranceBefore: tolerance, toleranceAfter: tolerance)
            }
        }

        private func reloadItem() {
            removeItemObservers()
            hasFinished = false
            hasReportedReady = false
            resetStateForNewItem()
            loadItem()
            startProgressTimer()
            player.play()
            restoreRateIfNeeded()
        }

        /// Отдаёт слой наружу на следующем витке главного актора: SwiftUI ещё не
        /// закончил обновление вьюхи, и менять `@State` прямо из `makeUIView` нельзя.
        private func reportPlayerLayer() {
            guard parent.onPlayerLayerReady != nil else { return }
            Task { @MainActor [weak self] in
                guard let self = self,
                      let onPlayerLayerReady = self.parent.onPlayerLayerReady else { return }
                onPlayerLayerReady(self.containerView.playerLayer)
            }
        }

        // MARK: Управление

        /// Тап-зоны: при `handlesTap == false` их полностью забирает SwiftUI-оверлей
        /// экрана, иначе координатор сам понимает touchesEnded контейнера.
        private func configureTapHandling() {
            guard parent.handlesTap else {
                containerView.onTap = nil
                return
            }
            containerView.onTap = { [weak self] in
                // Тап приходит из touchesEnded, а плеер — @MainActor.
                Task { @MainActor in
                    self?.handleTap()
                }
            }
        }

        /// Тап по кадру: с мостом — команда через `state` (тот же путь, что у кнопки
        /// оверлея), без моста — прежнее прямое переключение play/pause.
        private func handleTap() {
            guard let state = attachedState, state.player === player else {
                togglePlayback()
                return
            }
            let wasPlaying = isPlaying
            state.togglePlay()
            if wasPlaying {
                // Пауза: досохраняем позицию, не дожидаясь пятисекундного таймера.
                reportProgress()
            } else {
                activateAudioSession()
            }
        }

        private func togglePlayback() {
            if isPlaying {
                pause()
            } else {
                play()
            }
        }

        private func play() {
            activateAudioSession()
            player.play()
            restoreRateIfNeeded()
        }

        /// `AVPlayer.play()` всегда включает 1×; возвращаем скорость, выбранную
        /// в оверлее, после паузы/прерывания/смены серии.
        private func restoreRateIfNeeded() {
            guard let rate = attachedState?.rate, rate > 0, player.rate != rate else { return }
            player.rate = rate
        }

        private func pause() {
            player.pause()
            reportProgress()
        }

        private var isPlaying: Bool {
            if case .playing = player.timeControlStatus { return true }
            return false
        }

        private var isWaitingToPlay: Bool {
            if case .waitingToPlayAtSpecifiedRate = player.timeControlStatus { return true }
            return false
        }

        /// Тик наблюдателя плеера: публикация состояния в мост и одноразовое
        /// «видео пошло» для экрана.
        private func handlePlaybackTick() {
            publishPlaybackState()
            // Без моста (`state == nil`) — прежнее поведение: onReady по первому
            // playing-тику. С мостом готовность уже могла уйти раньше — из
            // `handleItemStatus`, поэтому здесь гейт на `isPlaying`.
            guard isPlaying else { return }
            // Играющее видео заведомо готово: страховка, если KVO-статус пришёл
            // без newValue. Повторно `markReady` не дёргаем, чтобы не публиковать
            // одно и то же состояние каждые 0.25 с.
            if let state = attachedState, state.player === player, !state.isReady {
                state.markReady()
            }
            reportReadyIfNeeded()
        }

        /// Одноразовый `onReady`: экран по нему убирает оверлей загрузки.
        private func reportReadyIfNeeded() {
            guard !hasReportedReady else { return }
            hasReportedReady = true
            parent.onReady?()
        }

        // MARK: Прогресс

        private func startProgressTimer() {
            guard progressTimer == nil else { return }
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.reportProgress()
                }
            }
            // .common — чтобы тик приходил и во время скролла/анимаций на экране.
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        }

        private func stopProgressTimer() {
            progressTimer?.invalidate()
            progressTimer = nil
        }

        private func reportProgress() {
            guard !hasFinished, player.currentItem != nil,
                  let seconds = currentSeconds() else { return }
            parent.onProgress?(seconds)
            if seconds > 0 {
                savePosition(seconds)
            }
        }

        private func currentSeconds() -> Int? {
            let time = player.currentTime()
            guard time.isValid, !time.isIndefinite else { return nil }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return Int(seconds)
        }

        private func currentDurationSeconds() -> Int? {
            guard let duration = player.currentItem?.duration,
                  duration.isValid, !duration.isIndefinite else { return nil }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return Int(seconds)
        }

        // MARK: PlaybackProgress

        /// Идентификаторы серии одной пачкой; `nil`, если прогресс некуда писать.
        private var playbackIDs: (releaseId: Int, sourceId: Int, episode: Int)? {
            guard let releaseId = parent.releaseId,
                  let sourceId = parent.sourceId,
                  let episode = parent.episodePosition else { return nil }
            return (releaseId, sourceId, episode)
        }

        private func savePosition(_ seconds: Int) {
            guard let ids = playbackIDs else { return }
            PlaybackProgress.shared.savePosition(seconds: seconds, releaseId: ids.releaseId, sourceId: ids.sourceId, position: ids.episode)
        }

        /// Сохраняет позицию и отправляет её в историю аккаунта.
        private func reportHistory(_ seconds: Int) {
            guard let ids = playbackIDs else { return }
            savePosition(seconds)
            Task { @MainActor in
                await PlaybackProgress.shared.reportHistory(releaseId: ids.releaseId, sourceId: ids.sourceId, position: ids.episode)
            }
        }

        /// Серия досмотрена: позицию обнуляем (чтобы не висела в «Продолжить»),
        /// на сервере ставим отметку о просмотре.
        private func markWatched() {
            guard let ids = playbackIDs else { return }
            savePosition(0)
            Task { @MainActor in
                await PlaybackProgress.shared.markWatched(releaseId: ids.releaseId, sourceId: ids.sourceId, position: ids.episode)
                await PlaybackProgress.shared.reportHistory(releaseId: ids.releaseId, sourceId: ids.sourceId, position: ids.episode)
            }
        }

        // MARK: Уведомления

        private func observePlayback() {
            // 0.25 с — время в оверлее обновляется плавно (ползунок, подписи),
            // но главный поток не дёргается на каждом кадре.
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackTick()
                }
            }

            // Пока время стоит (пауза, буферизация), периодический наблюдатель
            // молчит — а оверлею нужен точный play/pause. Поэтому смена
            // `timeControlStatus` публикует состояние сразу.
            timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.publishPlaybackState()
                }
            }
        }

        private func observeItem(_ item: AVPlayerItem) {
            removeItemObservers()
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finishPlayback()
                }
            }

            // `status` — сигнал готовности: KVO приходит и без воспроизведения
            // (пауза на старте, старт с сохранённой секунды). Колбэк приходит с
            // произвольного потока, поэтому на главный актор переходим сами и
            // проверяем, что item всё ещё текущий (за время перехода могли
            // перезагрузить серию).
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, change in
                let rawStatus = change.newValue?.rawValue
                let token = ObjectIdentifier(item)
                Task { @MainActor in
                    guard let self, let rawStatus,
                          let current = self.player.currentItem,
                          ObjectIdentifier(current) == token else { return }
                    self.handleItemStatus(rawValue: rawStatus)
                }
            }
            // Буфер опустел/наполнился — сразу обновляем `isBuffering` в мосте:
            // периодический наблюдатель молчит, пока время стоит.
            bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.publishBufferingState()
                }
            }
            likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.publishBufferingState()
                }
            }
        }

        private func finishPlayback() {
            guard !hasFinished else { return }
            hasFinished = true

            stopProgressTimer()
            // Досматриваем: оверлей должен увидеть паузу и время в конце.
            publishPlaybackState()

            if let duration = currentDurationSeconds() ?? currentSeconds() {
                parent.onProgress?(duration)
            }
            markWatched()
            parent.onFinished?()
        }

        private func removeItemObservers() {
            if let endObserver = endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            statusObservation?.invalidate()
            statusObservation = nil
            bufferEmptyObservation?.invalidate()
            bufferEmptyObservation = nil
            likelyToKeepUpObservation?.invalidate()
            likelyToKeepUpObservation = nil
        }

        private func removePlaybackObservers() {
            if let timeObserver = timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            timeControlObservation?.invalidate()
            timeControlObservation = nil
        }

        // MARK: Аудиосессия

        private func activateAudioSession() {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true)
            } catch {
                // Плеер не должен падать из-за аудиосессии: во время звонка или
                // в симуляторе активация может не пройти — видео всё равно покажем.
            }
        }

        private func deactivateAudioSession() {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }

        private func observeAudioInterruptions() {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let info = notification.userInfo
                let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor in
                    self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
                }
            }
        }

        private func removeInterruptionObserver() {
            if let interruptionObserver = interruptionObserver {
                NotificationCenter.default.removeObserver(interruptionObserver)
                self.interruptionObserver = nil
            }
        }

        private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
            guard let rawType = rawType,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

            switch type {
            case .began:
                wasPlayingBeforeInterruption = isPlaying
                pause()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
                wasPlayingBeforeInterruption = false
                if shouldResume {
                    play()
                }
            default:
                break
            }
        }
    }
}

// MARK: - AirPlay

/// Кнопка выбора AirPlay-устройства для панели управления плеером.
///
/// Обёртка над `AVRoutePickerView`: системная кнопка сама показывает список
/// получателей. `AVPlayer` по умолчанию разрешает внешнее воспроизведение,
/// поэтому отдельная настройка не нужна.
struct AirPlayButton: UIViewRepresentable {
    /// Цвет иконки; в тёмной теме плеера по умолчанию белый.
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = tintColor
        routePicker.activeTintColor = tintColor
        routePicker.prioritizesVideoDevices = true
        routePicker.backgroundColor = .clear
        return routePicker
    }

    func updateUIView(_ routePicker: AVRoutePickerView, context: Context) {
        routePicker.tintColor = tintColor
        routePicker.activeTintColor = tintColor
    }
}

// MARK: - Picture in Picture

/// Обёртка над `AVPictureInPictureController` для нашего `AVPlayerLayer`.
///
/// PiP — необязательная функция: где он не поддерживается, `init?` вернёт nil,
/// а `start()`/`stop()` молча ничего не делают, так что экран может не показывать
/// кнопку. Слой берётся из `NativePlayerView.onPlayerLayerReady`; контроллер нужно
/// держать живым, пока PiP может быть активен.
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    /// Поддерживает ли Picture in Picture текущее устройство.
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Возможен ли PiP прямо сейчас: слой в окне и видео готово к показу.
    var isSupported: Bool {
        controller.isPictureInPicturePossible
    }

    /// Идёт ли сейчас воспроизведение в PiP-окне.
    private(set) var isPictureInPictureActive = false

    /// Уведомляет экран о старте/остановке PiP — например, чтобы поменять иконку.
    var onStateChange: ((Bool) -> Void)?

    private let controller: AVPictureInPictureController

    /// Создаёт контроллер или возвращает nil, если PiP на устройстве недоступен.
    init?(playerLayer: AVPlayerLayer) {
        guard Self.isSupported,
              let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            return nil
        }
        self.controller = controller
        super.init()
        controller.delegate = self
    }

    /// Запускает PiP. Если сейчас это невозможно — молча ничего не делает.
    func start() {
        guard controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    /// Сворачивает PiP обратно в приложение.
    func stop() {
        guard controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = true
        onStateChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = false
        onStateChange?(false)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        onStateChange?(false)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
