import Foundation
import AVFoundation
import Combine

/// Состояние нативного воспроизведения и команды управления для UI плеера.
///
/// `NativePlayerView` создаёт `AVPlayer` внутри `UIViewRepresentable`, а SwiftUI-контролы
/// (play/pause, перемотка, время, скорость) живут снаружи — поэтому нужен мост:
/// состояние публикуется сюда, команды идут обратно в `AVPlayer`.
@MainActor
final class NativePlaybackState: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isBuffering: Bool = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    /// Пользователь тащит ползунок — обновления из AVPlayer не должны дёргать время.
    @Published var isSeeking: Bool = false

    /// `AVPlayer` доступен только для чтения (PiP/AirPlay/качество).
    private(set) var player: AVPlayer?

    /// Подключается координатором `NativePlayerView`; вызывается один раз на сессию.
    func attach(player: AVPlayer) {
        precondition(self.player == nil, "NativePlaybackState уже подключён к плееру")
        self.player = player
    }

    /// Отключается при dismantle: плеер уничтожается, состояние сбрасывается.
    func detach() {
        player = nil
        isPlaying = false
        isReady = false
        isBuffering = true
        currentTime = 0
        duration = 0
        rate = 1
        isSeeking = false
    }

    func markReady() { isReady = true }

    func update(time: Double, duration: Double, isPlaying: Bool, isBuffering: Bool, rate: Float) {
        if !isSeeking, time.isFinite {
            currentTime = max(0, time)
        }
        if duration.isFinite, duration > 0 {
            self.duration = duration
        }
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        if rate > 0 { self.rate = rate }
    }

    // MARK: - Команды

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
            if player.rate != rate { player.rate = rate }
        }
    }

    func play() {
        player?.play()
        player?.rate = rate
    }

    func pause() {
        player?.pause()
    }

    func seek(to seconds: Double, precise: Bool = true) {
        guard let player, seconds.isFinite else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: precise ? .zero : .positiveInfinity,
                    toleranceAfter: precise ? .zero : .positiveInfinity) { [weak self] _ in
            Task { @MainActor in self?.currentTime = target }
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.rate = rate
        }
    }

    /// Формат времени для контролов: `mm:ss` или `h:mm:ss`.
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
