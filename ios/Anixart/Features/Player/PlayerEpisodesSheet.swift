import SwiftUI

// MARK: - Модель шита

/// Серии выбранного источника для шита «Серии» в плеере.
///
/// Список берётся тем же запросом, что и секция «Серии» на странице релиза:
/// `episode/{releaseId}/{typeId}/{sourceId}` (`APIClient.episodes`). Экран плеера
/// передаёт id источника, поэтому шит работает и поверх нативного HLS, и поверх
/// HTML-плеера — если эти id известны.
///
/// Ошибку не пробрасываем наружу: видео продолжает играть, а шит показывает
/// текст ошибки и кнопку «Повторить».
@MainActor
final class PlayerEpisodesViewModel: ObservableObject {

    /// Серии источника; пусто, пока список не загружен.
    @Published var episodes: [Episode] = []

    /// Идёт запрос серий (спиннер вместо списка).
    @Published var isLoading = false

    /// Текст ошибки загрузки; `nil` — ошибки нет.
    @Published var errorMessage: String?

    private let releaseId: Int?
    private let typeId: Int?
    private let sourceId: Int?

    private let api = APIClient.shared

    init(releaseId: Int?, typeId: Int?, sourceId: Int?) {
        self.releaseId = releaseId
        self.typeId = typeId
        self.sourceId = sourceId
    }

    /// Известны ли все id: без любого из них список серий не запросить.
    var isAvailable: Bool {
        releaseId != nil && typeId != nil && sourceId != nil
    }

    /// Загрузить список серий.
    ///
    /// Если хотя бы одного id нет (например, плеер открыт по прямой ссылке),
    /// списка не будет — оставляем пусто без ошибки: это не сбой, а отсутствие
    /// контекста релиза.
    func load() async {
        guard !isLoading else { return }
        guard let releaseId, let typeId, let sourceId else {
            episodes = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            episodes = try await api.episodes(releaseId: releaseId, typeId: typeId, sourceId: sourceId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Экран

/// Шит «Серии» прямо в плеере: выбрать серию, не выходя на страницу релиза.
///
/// Переключение делает экран плеера: шит только сообщает выбор через `onSelect`
/// и закрывается сам. Текущая серия выделена акцентом, просмотренные отмечены
/// галочкой, филлеры — пометкой «филлер» (как на странице релиза).
///
/// Список листается `ScrollView` + `LazyVStack`, а не `List`: нужен тёмный фон
/// Anixart без системных разделителей и отступов.
@MainActor
struct PlayerEpisodesSheet: View {

    // MARK: - Входные данные

    /// Id релиза для `episode/{releaseId}/{typeId}/{sourceId}`.
    let releaseId: Int?
    /// Id озвучки.
    let typeId: Int?
    /// Id источника (плеера).
    let sourceId: Int?

    /// Позиция играющей сейчас серии: её строка выделена акцентом.
    let currentPosition: Int?

    /// Выбор серии: плеер запускает её вместо текущей.
    let onSelect: (Episode) -> Void

    // MARK: - Состояние

    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: PlayerEpisodesViewModel

    // MARK: - Инициализация

    init(releaseId: Int?,
         typeId: Int?,
         sourceId: Int?,
         currentPosition: Int?,
         onSelect: @escaping (Episode) -> Void) {
        self.releaseId = releaseId
        self.typeId = typeId
        self.sourceId = sourceId
        self.currentPosition = currentPosition
        self.onSelect = onSelect
        _model = StateObject(wrappedValue: PlayerEpisodesViewModel(releaseId: releaseId,
                                                                  typeId: typeId,
                                                                  sourceId: sourceId))
    }

    // MARK: - Каркас

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenBackground()
                .navigationTitle("Серии")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        closeButton
                    }
                }
        }
        .preferredColorScheme(.dark)
        // `.task` — а не `.onAppear` + Task: SwiftUI сам отменит запрос при
        // закрытии шита, и размонтирование не оставит «висящую» загрузку.
        .task { await model.load() }
        .playerEpisodesAccessibilityIdentifier("player-episodes-sheet")
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        // Не «Закрыть»: в плеере уже есть крестик с такой подписью, а XCUITest
        // по точному label нашёл бы два элемента.
        .accessibilityLabel("Закрыть список серий")
        .playerEpisodesAccessibilityIdentifier("player-episodes-close")
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.episodes.isEmpty {
            loadingState
        } else if model.episodes.isEmpty, let message = model.errorMessage {
            errorState(message)
        } else if model.episodes.isEmpty {
            emptyState
        } else {
            episodeList
        }
    }

    private var episodeList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.episodes) { episode in
                    episodeRow(episode)

                    // Разделитель между строками, как в секции «Серии» на релизе.
                    Divider()
                        .overlay(Theme.separator)
                        .padding(.leading, 16)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Строка серии

    /// Строка списка: номер серии, пометки и отметка текущей серии.
    ///
    /// Вся строка — одна кнопка: тап выбирает серию и закрывает шит. Подпись
    /// доступности — «Серия N» (идентификатор `player-episode-N` нужен UI-тестам).
    private func episodeRow(_ episode: Episode) -> some View {
        let isCurrent = episode.position == currentPosition

        return Button {
            onSelect(episode)
            // Шит закрываем сами: пользователь выбрал серию — плеер должен
            // оказаться на экране сразу, а не после ручного свайпа.
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text("Серия \(episode.position)")
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)

                if episode.isFiller == true {
                    fillerBadge
                }

                Spacer(minLength: 8)

                if episode.isWatched == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Просмотрена")
                }

                Image(systemName: isCurrent ? "play.fill" : "play")
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(isCurrent ? Theme.accentSoft : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Серия \(episode.position)")
        .playerEpisodesAccessibilityIdentifier("player-episode-\(episode.position)")
    }

    private var fillerBadge: some View {
        Text("филлер")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceHigh, in: Capsule())
    }

    // MARK: - Состояния

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(Theme.accent)

            Text("Загружаем серии…")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)

            Text("Не удалось загрузить серии")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button {
                Task { await model.load() }
            } label: {
                Text("Повторить")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Повторить загрузку серий")
            .playerEpisodesAccessibilityIdentifier("player-episodes-retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)

            Text(emptyTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(emptyHint)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityLabel(emptyTitle)
    }

    /// Без id источника списка нет — это не «пустой источник», а другой случай.
    private var emptyTitle: String {
        model.isAvailable ? "В этом источнике нет серий" : "Список серий недоступен"
    }

    private var emptyHint: String {
        if model.isAvailable {
            return "Выберите другую озвучку или источник на странице релиза"
        }
        return "Плеер открыт без привязки к релизу — список серий не загрузить"
    }
}

// MARK: - Совместимость со стаб-стендом

// `tools/StubSwiftUI/StubKit.swift` не моделирует `accessibilityIdentifier`:
// под Linux-проверкой обёртка — no-op, на iOS используется настоящий модификатор
// (та же схема, что в `PlayerControlsOverlay.swift`).
private extension View {
    @ViewBuilder
    func playerEpisodesAccessibilityIdentifier(_ identifier: String) -> some View {
        #if canImport(Darwin)
        accessibilityIdentifier(identifier)
        #else
        self
        #endif
    }
}
