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

/// UIView с `AVPlayerLayer` и спиннером буферизации.
///
/// Слои живут саблеером контейнера, frame обновляется в `layoutSubviews`: размер
/// задаёт SwiftUI (в том числе при повороте), видео вписано по `.resizeAspect`.
final class PlayerContainerView: UIView {
    let playerLayer: AVPlayerLayer
    let activityIndicator: UIActivityIndicatorView

    /// Тап по видео — переключение play/pause.
    var onTap: (() -> Void)?

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        activityIndicator = UIActivityIndicatorView(style: .large)
        super.init(frame: .zero)

        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button

        layer.addSublayer(playerLayer)

        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        activityIndicator.startAnimating()
        addSubview(activityIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
        activityIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
        private var stallObserver: NSObjectProtocol?
        private var interruptionObserver: NSObjectProtocol?
        private var hasStarted = false
        private var hasFinished = false
        private var hasReportedReady = false
        private var wasPlayingBeforeInterruption = false

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

            containerView.onTap = { [weak self] in
                // Тап приходит из touchesEnded, а плеер — @MainActor.
                Task { @MainActor in
                    self?.togglePlayback()
                }
            }
            containerView.accessibilityLabel = parent.title

            activateAudioSession()
            loadItem()
            observePlayback()
            observeAudioInterruptions()
            startProgressTimer()
            player.play()
            reportPlayerLayer()
        }

        func update(parent: NativePlayerView) {
            let urlChanged = parent.url != self.parent.url
            self.parent = parent
            containerView.accessibilityLabel = parent.title
            if urlChanged {
                reloadItem()
            }
        }

        func stop() {
            stopProgressTimer()
            removePlaybackObservers()
            removeItemObservers()
            removeInterruptionObserver()

            if !hasFinished, let seconds = currentSeconds(), seconds > 0 {
                // Последние секунды иначе потеряются: таймер мог не успеть.
                // Нулевую позицию не сохраняем, чтобы не стереть прошлый прогресс.
                parent.onProgress?(seconds)
                reportHistory(seconds)
            }

            player.pause()
            player.replaceCurrentItem(with: nil)
            containerView.activityIndicator.stopAnimating()
            deactivateAudioSession()
        }

        deinit {
            progressTimer?.invalidate()
            if let timeObserver = timeObserver {
                player.removeTimeObserver(timeObserver)
            }
        }

        // MARK: Загрузка

        private func loadItem() {
            let item = AVPlayerItem(url: parent.url)
            player.replaceCurrentItem(with: item)
            observeItem(item)

            if parent.startPosition > 0 {
                let position = CMTime(seconds: Double(parent.startPosition), preferredTimescale: 600)
                player.seek(to: position)
            }
            containerView.activityIndicator.startAnimating()
        }

        private func reloadItem() {
            removeItemObservers()
            hasFinished = false
            hasReportedReady = false
            loadItem()
            startProgressTimer()
            player.play()
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
            if !isPlaying {
                containerView.activityIndicator.startAnimating()
            }
        }

        private func pause() {
            player.pause()
            containerView.activityIndicator.stopAnimating()
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

        private func updateBufferingIndicator() {
            if isPlaying {
                containerView.activityIndicator.stopAnimating()
            } else if isWaitingToPlay {
                containerView.activityIndicator.startAnimating()
            }
        }

        /// Тик наблюдателя плеера: спиннер + одноразовое «видео пошло».
        private func handlePlaybackTick() {
            updateBufferingIndicator()
            guard !hasReportedReady, isPlaying else { return }
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
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackTick()
                }
            }

            // «Залипание» сети: время не идёт и наблюдатель молчит, поэтому
            // спиннер включаем по отдельному уведомлению.
            stallObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.playbackStalledNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.containerView.activityIndicator.startAnimating()
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
        }

        private func finishPlayback() {
            guard !hasFinished else { return }
            hasFinished = true

            stopProgressTimer()
            containerView.activityIndicator.stopAnimating()

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
        }

        private func removePlaybackObservers() {
            if let timeObserver = timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            if let stallObserver = stallObserver {
                NotificationCenter.default.removeObserver(stallObserver)
                self.stallObserver = nil
            }
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
