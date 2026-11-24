import AVFoundation
import Foundation
import MediaPlayer

// MARK: - Экран блокировки и внешние кнопки

/// Отдаёт серию системе: карточка «сейчас играет» и внешние кнопки управления.
///
/// ## Зачем
///
/// Плеер играет в фоне (`UIBackgroundModes: audio`) и в PiP, но до этого
/// управлять им можно было только с экрана приложения: на локскрине не было
/// карточки, кнопка на наушниках и «пауза» в пункте управления ничего не
/// делали, а после паузы с наушников видео продолжало играть молча.
///
/// Здесь две системные подсистемы:
///
/// * `MPNowPlayingInfoCenter` — что показывать: название серии, длительность,
///   позицию и скорость. iOS рисует из этого карточку на локскрине и в
///   пункте управления и сама двигает ползунок между обновлениями
///   (по `elapsed` + `rate`), поэтому обновлять её каждые 0,25 с не нужно —
///   см. `minimumPushInterval`.
/// * `MPRemoteCommandCenter` — что нажали: play/pause/toggle, ±10 секунд,
///   перетаскивание позиции на локскрине и «следующий трек» (у нас —
///   следующая серия).
///
/// ## Как подключено
///
/// Владелец — координатор `NativePlayerView`: он вызывает `activate(commands:)`
/// при старте, `update(...)` из публикации состояния и `deactivate()` при
/// разборке вьюхи. Команды уходят тем же путём, что и кнопки оверлея
/// (`NativePlaybackState`), поэтому состояние интерфейса и системной карточки
/// не расходятся.
///
/// Карточку обязательно снимать в `deactivate()`: иначе после закрытия плеера
/// на локскрине остаётся «призрак» серии, а команды продолжают приходить в
/// уже мёртвый координатор.
@MainActor
final class NowPlayingController {

    // MARK: - Команды

    /// Что делать по нажатию внешней кнопки. Все замыкания вызываются на
    /// главном акторе; `next == nil` — следующей серии нет, кнопка выключена.
    struct Commands {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        /// Относительная перемотка в секундах (`+10` / `-10`).
        let skip: (Double) -> Void
        /// Абсолютная позиция в секундах (ползунок на локскрине).
        let seek: (Double) -> Void
        /// Следующая серия; `nil` — кнопку не включаем.
        let next: (() -> Void)?
    }

    /// Шаг кнопок «назад/вперёд» на локскрине — как у двойного тапа в плеере.
    private static let skipInterval: Double = 10

    /// Минимальный интервал между обновлениями карточки: состояние публикуется
    /// каждые 0,25 с, но локскрину хватает позиции раз в пару секунд — между
    /// обновлениями он двигает ползунок сам. Смена play/pause проходит сразу.
    private static let minimumPushInterval: TimeInterval = 2

    /// Зарегистрированные обработчики — их обязательно снять в `deactivate()`.
    private var targets: [(command: MPRemoteCommand, token: Any)] = []

    private var lastPushedAt: Date?
    private var lastPushedIsPlaying: Bool?
    private var isActive = false

    // MARK: - Жизненный цикл

    /// Подписывается на внешние кнопки. Повторный вызов сначала снимает старые
    /// обработчики: иначе после пересоздания плеера на одну кнопку приходило бы
    /// несколько команд.
    func activate(commands: Commands) {
        removeTargets()
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { commands.play() }
        add(center.pauseCommand) { commands.pause() }
        add(center.togglePlayPauseCommand) { commands.toggle() }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand) { commands.skip(Self.skipInterval) }
        add(center.skipBackwardCommand) { commands.skip(-Self.skipInterval) }

        addPositionTarget(center.changePlaybackPositionCommand, seek: commands.seek)

        if let next = commands.next {
            add(center.nextTrackCommand) { next() }
        }
        // Следующая серия находится уже после старта (`NextEpisodeService`),
        // поэтому включает кнопку `update(hasNext:)`, а не регистрация.
        center.nextTrackCommand.isEnabled = false
    }

    /// Обновляет карточку «сейчас играет».
    ///
    /// - Parameters:
    ///   - title: название серии (оно же в плеере).
    ///   - isPlaying: идёт ли воспроизведение — от этого зависит, двигает ли
    ///     система ползунок.
    ///   - currentTime: позиция в секундах.
    ///   - duration: длительность; `0`/`NaN` — пропускаем поле, иначе локскрин
    ///     покажет «бесконечную» серию.
    ///   - rate: текущая скорость (0,5–2×).
    ///   - hasNext: есть ли следующая серия — включает кнопку «следующий трек».
    func update(title: String,
                isPlaying: Bool,
                currentTime: Double,
                duration: Double,
                rate: Float,
                hasNext: Bool) {
        guard isActive else { return }
        guard shouldPush(isPlaying: isPlaying) else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0
        ]
        if currentTime.isFinite, currentTime >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
    }

    /// Снимает карточку и все обработчики: плеер закрыт.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        removeTargets()
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastPushedAt = nil
        lastPushedIsPlaying = nil
    }

    // MARK: - Внутреннее

    /// Пропускает слишком частые обновления: позицию двигает сама система,
    /// а вот смену play/pause надо отдать немедленно.
    private func shouldPush(isPlaying: Bool, now: Date = Date()) -> Bool {
        // Отметки обновляются только при реальной отправке: иначе каждый
        // пропущенный вызов сдвигал бы `lastPushedAt` вперёд, интервал никогда
        // не набирался бы и карточка замерла бы на первой позиции.
        if let lastPushedAt,
           lastPushedIsPlaying == isPlaying,
           now.timeIntervalSince(lastPushedAt) < Self.minimumPushInterval {
            return false
        }
        lastPushedIsPlaying = isPlaying
        lastPushedAt = now
        return true
    }

    /// Регистрирует обработчик команды.
    ///
    /// Замыкание `MPRemoteCommand` не обещает главный актор (и не `@Sendable`),
    /// поэтому на актор переходим сами — тем же `Task { @MainActor in … }`, что
    /// и остальные колбэки плеера (KVO, уведомления аудиосессии). Системе
    /// отвечаем `.success` сразу: результат команды асинхронный.
    private func add(_ command: MPRemoteCommand, handler: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            Task { @MainActor in handler() }
            return .success
        }
        targets.append((command, token))
    }

    /// Перетаскивание позиции на локскрине: из события берём только секунды,
    /// чтобы на актор уехало значение, а не объект события.
    private func addPositionTarget(_ command: MPRemoteCommand, seek: @escaping @MainActor (Double) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let seconds = positionEvent.positionTime
            Task { @MainActor in seek(seconds) }
            return .success
        }
        targets.append((command, token))
    }

    private func removeTargets() {
        for entry in targets {
            entry.command.removeTarget(entry.token)
        }
        targets.removeAll()
    }
}
