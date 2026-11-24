import SwiftUI

// MARK: - Оверлей управления

/// Полноэкранный слой управления поверх видео — как в оригинальном Anixart.
///
/// Вёрстка из трёх зон:
/// * верх — закрыть, название серии, качество, скорость, Picture in Picture;
/// * центр — крупная кнопка play/pause (во время буферизации — спиннер);
/// * низ — текущее время, кастомная полоса перемотки, длительность и ряд
///   кнопок «−10 с / следующая серия / +10 с».
///
/// Оверлей ничего не решает сам: состояние (`NativePlaybackState`) и команды
/// (`togglePlay`, `seek`, `skip`, `setRate`) приходят извне, поэтому один и тот
/// же слой подходит и нативному `AVPlayer`, и будущим источникам.
///
/// Видимостью владеет `PlayerView` (тап/авто-скрытие): здесь только плавное
/// изменение прозрачности и `allowsHitTesting(controlsVisible)`, чтобы скрытый
/// слой не перехватывал тапы по видео.
///
/// Полоса перемотки сделана вручную (`GeometryReader` + `DragGesture`), а не
/// `Slider`: нужен акцентный стиль Anixart, светлая точка и корректное время
/// прямо во время жеста. Пока пользователь тащит ползунок, время берётся из
/// локального `dragValue`, а не из плеера (иначе `AVPlayer` дёргает его назад).
///
/// Слой прозрачен для тапов вне контролов: градиентная подложка отключена от
/// hit-testing, поэтому тап по «пустому» видео уходит слою-обработчику под
/// оверлеем (`PlayerView` вешает туда показ/скрытие и двойной тап).
///
/// Слой совместимости в конце файла: стаб-стенд `tools/StubSwiftUI` не моделирует
/// `DragGesture`, `.animation(_:value:)`, `.allowsHitTesting` и
/// `accessibilityIdentifier` — под Linux (проверка `check.py all`) это no-op,
/// под iOS-сборкой используются настоящие модификаторы SwiftUI.
@MainActor
struct PlayerControlsOverlay: View {

    // MARK: - Входные данные

    /// Состояние нативного воспроизведения: время, длительность, play/pause.
    /// `@ObservedObject`, иначе оверлей не перерисуется на изменения `@Published`.
    @ObservedObject private var state: NativePlaybackState

    /// Название серии; одна строка, обрезается многоточием.
    private let title: String

    /// Варианты качества из master-плейлиста; меню — только если их больше одного.
    private let qualities: [VideoQualityVariant]

    /// Текущее качество (`nil` — качество ещё не выбрано, показываем «auto»).
    private let selectedQuality: VideoQualityVariant?

    /// Выбор качества пользователем (плеер перезапускает поток с нового URL).
    private let onSelectQuality: (VideoQualityVariant) -> Void

    /// Крестик в верхнем левом углу.
    private let onClose: () -> Void

    /// «Следующая серия»; `nil` — следующей серии нет, кнопка не показывается.
    private let onNextEpisode: (() -> Void)?

    /// PiP-кнопка; `nil` — PiP недоступен (или им управляют снаружи иначе).
    private let onTogglePiP: (() -> Void)?

    /// Показывать ли PiP-кнопку (на устройстве/источнике PiP может быть недоступен).
    private let showPiP: Bool

    /// Видимость контролов: тапом по видео `PlayerView` переключает это значение.
    private let controlsVisible: Bool

    // MARK: - Локальное состояние

    /// Позиция, на которую пользователь целится перетаскиванием ползунка, в секундах.
    /// Пока жест идёт, UI показывает её вместо `state.currentTime`.
    @State private var dragValue: Double?

    /// Скорости из меню — как в оригинальном Anixart.
    private static let speedOptions: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// Размеры и отступы контролов.
    private enum Metrics {
        /// Минимальная площадь тач-зоны по HIG — 44 × 44 pt.
        static let touchTarget: CGFloat = 44
        /// Диаметр центральной кнопки play/pause.
        static let playButton: CGFloat = 72
        /// Высота площадки полосы перемотки (тап/жест по ней) — по HIG ≥ 44 pt.
        static let seekBarHeight: CGFloat = 44
        /// Диаметр светлой точки ползунка.
        static let thumbDiameter: CGFloat = 16
        /// Горизонтальные поля нижней панели и верхней строки.
        static let horizontalInset: CGFloat = 16
    }

    // MARK: - Инициализация

    init(state: NativePlaybackState,
         title: String,
         qualities: [VideoQualityVariant],
         selectedQuality: VideoQualityVariant? = nil,
         onSelectQuality: @escaping (VideoQualityVariant) -> Void,
         onClose: @escaping () -> Void,
         onNextEpisode: (() -> Void)? = nil,
         onTogglePiP: (() -> Void)? = nil,
         showPiP: Bool = true,
         controlsVisible: Bool) {
        _state = ObservedObject(wrappedValue: state)
        self.title = title
        self.qualities = qualities
        self.selectedQuality = selectedQuality
        self.onSelectQuality = onSelectQuality
        self.onClose = onClose
        self.onNextEpisode = onNextEpisode
        self.onTogglePiP = onTogglePiP
        self.showPiP = showPiP
        self.controlsVisible = controlsVisible
    }

    // MARK: - Каркас

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.top, 8)

                Spacer(minLength: 0)

                bottomBar
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.bottom, 16)
            }

            centerControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Подложка декоративная: она не должна перехватывать тапы по видео.
        .background(
            LinearGradient(
                colors: [.black.opacity(0.75), .clear, .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .playerControlsHitTesting(false)
        )
        .opacity(controlsVisible ? 1 : 0)
        .playerControlsAnimation(visible: controlsVisible)
        .playerControlsHitTesting(controlsVisible)
    }

    // MARK: - Верхняя строка

    private var topBar: some View {
        HStack(spacing: 8) {
            closeButton

            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                // Название уже есть в навбаре `PlayerView`: второй staticText
                // с тем же текстом ломает UI-тесты на `"1 серия"`.
                .playerControlsAccessibilityHidden()

            Spacer(minLength: 8)

            if qualities.count > 1 {
                qualityMenu
            }

            speedMenu

            if showPiP, let onTogglePiP = onTogglePiP {
                pipButton(onTogglePiP)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
        }
        .buttonStyle(.plain)
        // Не «Закрыть»: в навбаре `PlayerView` уже есть кнопка с такой подписью,
        // а XCUITest по точному label нашёл бы две.
        .accessibilityLabel("Закрыть плеер")
        .playerControlsAccessibilityIdentifier("player-close")
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(qualities) { variant in
                Button {
                    onSelectQuality(variant)
                } label: {
                    if isCurrentQuality(variant) {
                        Label(variant.label, systemImage: "checkmark")
                    } else {
                        Text(variant.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(qualityLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .frame(minWidth: Metrics.touchTarget, minHeight: Metrics.touchTarget)
        }
        .tint(Theme.accent)
        .accessibilityLabel("Качество видео")
        .playerControlsAccessibilityIdentifier("player-quality")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speedOptions, id: \.self) { speed in
                Button {
                    state.setRate(speed)
                } label: {
                    if isCurrentSpeed(speed) {
                        Label(Self.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(Self.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(Self.speedLabel(state.rate))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: Metrics.touchTarget, minHeight: Metrics.touchTarget)
        }
        .tint(Theme.accent)
        .accessibilityLabel("Скорость воспроизведения")
        .playerControlsAccessibilityIdentifier("player-speed")
    }

    private func pipButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "pip.enter")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Картинка в картинке")
        .playerControlsAccessibilityIdentifier("player-pip")
    }

    // MARK: - Центр

    private var centerControls: some View {
        VStack(spacing: 14) {
            Button {
                state.togglePlay()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    // У play.fill оптический центр смещён влево — компенсируем.
                    .offset(x: state.isPlaying ? 0 : 2)
                    .frame(width: Metrics.playButton, height: Metrics.playButton)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isPlaying ? "Пауза" : "Воспроизвести")
            .playerControlsAccessibilityIdentifier("player-play-pause")

            // Спиннер не подменяет кнопку: пауза/плей должны оставаться доступными
            // (как в оригинальном плеере), а буферизация — отдельной подсказкой.
            if state.isBuffering && state.isReady {
                ProgressView()
                    .tint(Theme.accent)
                    .accessibilityLabel("Загрузка")
                    .playerControlsAccessibilityIdentifier("player-buffering")
            }
        }
    }

    // MARK: - Нижняя панель

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(NativePlaybackState.timeText(displayedTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: Metrics.touchTarget, alignment: .leading)
                    .accessibilityLabel("Текущее время")
                    .playerControlsAccessibilityIdentifier("player-time-current")

                seekBar

                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: Metrics.touchTarget, alignment: .trailing)
                    .accessibilityLabel("Длительность")
                    .playerControlsAccessibilityIdentifier("player-time-duration")
            }

            transportControls
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            skipButton(by: -10,
                       systemImage: "gobackward.10",
                       title: "−10 с",
                       accessibilityTitle: "Назад на 10 секунд",
                       identifier: "player-skip-back")

            if let onNextEpisode = onNextEpisode {
                Button(action: onNextEpisode) {
                    Label("Следующая серия", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: Metrics.touchTarget)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Следующая серия")
                .playerControlsAccessibilityIdentifier("player-next-episode")
            }

            skipButton(by: 10,
                       systemImage: "goforward.10",
                       title: "+10 с",
                       accessibilityTitle: "Вперёд на 10 секунд",
                       identifier: "player-skip-forward")
        }
    }

    private func skipButton(by seconds: Double,
                            systemImage: String,
                            title: String,
                            accessibilityTitle: String,
                            identifier: String) -> some View {
        Button {
            state.skip(by: seconds)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(minWidth: 56, minHeight: Metrics.touchTarget)
            .background(Color.white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .playerControlsAccessibilityIdentifier(identifier)
    }

    // MARK: - Полоса перемотки

    /// Полоса перемотки: заполнение акцентом и светлая точка.
    ///
    /// Жест и тап обрабатывает `playerControlsSeekInteraction`: на iOS это
    /// `DragGesture(minimumDistance: 0)`, поэтому и перетаскивание, и короткий
    /// тап по полосе перематывают к позиции.
    private var seekBar: some View {
        GeometryReader { proxy in
            seekBarContent(width: max(proxy.size.width, 1))
        }
        .frame(height: Metrics.seekBarHeight)
    }

    private func seekBarContent(width: CGFloat) -> some View {
        seekBarTrack(width: width)
            .playerControlsSeekInteraction(
                valueText: NativePlaybackState.timeText(displayedTime),
                onChanged: { x in updateDrag(toX: x, width: width) },
                onEnded: { x in endDrag(atX: x, width: width) }
            )
    }

    /// Визуальная часть полосы: подложка, заполнение и точка.
    private func seekBarTrack(width: CGFloat) -> some View {
        let fraction = CGFloat(progress)
        let travel = max(width - Metrics.thumbDiameter, 0)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: width, height: 4)

            Capsule()
                .fill(Theme.accent)
                .frame(width: max(width * fraction, 0), height: 4)

            Circle()
                .fill(Color.white)
                .frame(width: Metrics.thumbDiameter, height: Metrics.thumbDiameter)
                .offset(x: travel * fraction)
        }
        .frame(width: width, height: Metrics.seekBarHeight, alignment: .leading)
    }

    // MARK: - Перемотка: состояние и расчёты

    /// Время, которое видит пользователь: во время жеста — цель жеста.
    private var displayedTime: Double {
        if let dragValue {
            return dragValue
        }
        return state.currentTime
    }

    /// Заполнение полосы от 0 до 1. Пока длительность неизвестна — полоса пустая.
    private var progress: Double {
        guard state.duration > 0 else { return 0 }
        return min(max(displayedTime / state.duration, 0), 1)
    }

    private var durationText: String {
        state.duration > 0 ? NativePlaybackState.timeText(state.duration) : "--:--"
    }

    /// Пользователь ведёт палец: фиксируем `isSeeking` и показываем цель жеста.
    private func updateDrag(toX x: CGFloat, width: CGFloat) {
        guard width > 0, state.duration > 0 else { return }
        state.isSeeking = true
        dragValue = seconds(atX: x, width: width)
    }

    /// Жест закончен: перематываем плеер и отпускаем время обратно в `AVPlayer`.
    private func endDrag(atX x: CGFloat, width: CGFloat) {
        guard width > 0, state.duration > 0 else {
            state.isSeeking = false
            dragValue = nil
            return
        }

        let target = seconds(atX: x, width: width)
        dragValue = target
        state.seek(to: target)
        state.isSeeking = false
        dragValue = nil
    }

    /// Позиция в секундах для точки `x` на полосе шириной `width`.
    private func seconds(atX x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / width), 0), 1)
        return fraction * state.duration
    }

    // MARK: - Вспомогательные подписи

    /// Подпись текущего качества: выбранное или первое доступное.
    private var qualityLabel: String {
        if let selectedQuality = selectedQuality {
            return selectedQuality.label
        }
        return qualities.first?.label ?? "auto"
    }

    private func isCurrentQuality(_ variant: VideoQualityVariant) -> Bool {
        guard let selectedQuality = selectedQuality else { return false }
        return variant.id == selectedQuality.id || variant.label == selectedQuality.label
    }

    private func isCurrentSpeed(_ speed: Float) -> Bool {
        abs(state.rate - speed) < 0.001
    }

    /// «1×», «0.75×», «1.25×» — без локализованных разделителей.
    private static func speedLabel(_ speed: Float) -> String {
        let value = Double(speed)
        if value == value.rounded() {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }
}

// MARK: - Совместимость со стаб-стендом

// `tools/StubSwiftUI/StubKit.swift` описывает только часть SwiftUI, достаточную
// для проверки логики экранов, и намеренно не моделирует жесты, анимации и
// accessibility-идентификаторы. Поэтому недостающие модификаторы собраны в
// маленькие обёртки: под Linux-проверкой они ничего не делают (typecheck идёт),
// на iOS работают настоящие модификаторы SwiftUI (их проверяет xcodebuild).

private extension View {
    /// `accessibilityIdentifier(_:)` — код UI-тестов ищет элементы по нему.
    @ViewBuilder
    func playerControlsAccessibilityIdentifier(_ identifier: String) -> some View {
        #if canImport(Darwin)
        accessibilityIdentifier(identifier)
        #else
        self
        #endif
    }

    /// Прячет декоративные элементы из дерева доступности (UI-тестов).
    @ViewBuilder
    func playerControlsAccessibilityHidden() -> some View {
        #if canImport(Darwin)
        accessibilityHidden(true)
        #else
        self
        #endif
    }

    /// Плавное появление/скрытие контролов — `.animation(_:value:)`.
    @ViewBuilder
    func playerControlsAnimation(visible: Bool) -> some View {
        #if canImport(Darwin)
        animation(.easeInOut(duration: 0.2), value: visible)
        #else
        self
        #endif
    }

    /// Пропуск тапов, когда контролы скрыты (и для декоративной подложки).
    @ViewBuilder
    func playerControlsHitTesting(_ enabled: Bool) -> some View {
        #if canImport(Darwin)
        allowsHitTesting(enabled)
        #else
        self
        #endif
    }

    /// Перемотка жестом и тапом: `DragGesture(minimumDistance: 0)` даёт и drag,
    /// и короткий тап по полосе. На iOS элемент заодно становится единым
    /// accessibility-элементом с подписью «Перемотка» и текущим временем.
    @ViewBuilder
    func playerControlsSeekInteraction(valueText: String,
                                       onChanged: @escaping (CGFloat) -> Void,
                                       onEnded: @escaping (CGFloat) -> Void) -> some View {
        #if canImport(Darwin)
        contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChanged(value.location.x)
                    }
                    .onEnded { value in
                        onEnded(value.location.x)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Перемотка")
            .accessibilityValue(valueText)
            .accessibilityIdentifier("player-seek")
        #else
        self
        #endif
    }
}

// MARK: - Заглушка контракта для Linux-стенда

#if !canImport(Darwin)
/// Минимальная заглушка `NativePlaybackState` для стаб-проверки.
///
/// Сам `NativePlaybackState.swift` исключён из блоб-проверки: он работает с
/// `AVFoundation` (`AVPlayer`, `CMTime`), которые стаб-стенд не моделирует
/// (`tools/StubSwiftUI/check.py`, `SKIP_STUBS`). Оверлею нужен только его API,
/// поэтому под Linux контракт объявлен здесь. На iOS этот блок не компилируется,
/// и типом остаётся настоящий `NativePlaybackState` из соседнего файла.
@MainActor
final class NativePlaybackState: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isBuffering: Bool = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    @Published var isSeeking: Bool = false
    private(set) var player: AVPlayer?

    init() {}

    func togglePlay() {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double, precise: Bool = true) {}
    func skip(by seconds: Double) {}
    func setRate(_ rate: Float) {}

    static func timeText(_ seconds: Double) -> String { "0:00" }
}
#endif
