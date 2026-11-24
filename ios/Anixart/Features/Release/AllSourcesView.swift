import SwiftUI

// MARK: - Все источники релиза
//
// Источники привязаны к озвучке: `episode/{releaseId}/{typeId}` отдаёт плееры
// только выбранного типа — у AniDUB обычно Kodik, у AniLibria — Libria,
// у субтитров — Sibnet. В секции «Серии» поэтому видно лишь источники текущей
// озвучки, и кажется, что других плееров у релиза нет. Этот экран показывает
// сводку по всем озвучкам: полный список (Kodik, Sibnet, Libria, RuTube, TSM…)
// с числом серий у каждого, чтобы сразу переключиться на нужный источник.

// MARK: - Экран

/// Все источники релиза, сгруппированные по озвучкам.
///
/// Данные готовит `ReleaseViewModel` (`allSourcesByType`), экран их только рисует:
/// загрузку и переключение серий держит страница релиза, а выбор уходит наружу
/// замыканием `onPick` — она же закрывает этот шит.
struct AllSourcesView: View {
    /// Источники по озвучкам в порядке сервера.
    let sourcesByType: [(type: EpisodeType, sources: [EpisodeSource])]
    /// Озвучки, у которых не удалось загрузить источники — показываем текстом,
    /// чтобы сбой сети не выглядел как «у релиза только Kodik».
    let failures: [String]
    /// Идёт фоновая загрузка сводки: показываем прогресс, а не пустое состояние.
    let isLoading: Bool
    /// Текущая выбранная озвучка и источник — для отметки «уже открыт».
    let selectedTypeId: Int?
    let selectedSourceId: Int?
    /// Выбор источника: страница релиза закроет шит и переключит тип/источник.
    let onPick: (EpisodeType, EpisodeSource) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Явный инициализатор: memberwise-init не годится — замыканию нужен
    /// `@escaping`, а `private`-поле `dismiss` делает синтезированный init приватным.
    init(
        sourcesByType: [(type: EpisodeType, sources: [EpisodeSource])],
        failures: [String] = [],
        isLoading: Bool,
        selectedTypeId: Int? = nil,
        selectedSourceId: Int? = nil,
        onPick: @escaping (EpisodeType, EpisodeSource) -> Void
    ) {
        self.sourcesByType = sourcesByType
        self.failures = failures
        self.isLoading = isLoading
        self.selectedTypeId = selectedTypeId
        self.selectedSourceId = selectedSourceId
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .screenBackground()
            .navigationTitle("Все источники")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        if visibleGroups.isEmpty && isLoading {
            loadingState
        } else if visibleGroups.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 18) {
                hint

                ForEach(visibleGroups.indices, id: \.self) { index in
                    typeSection(visibleGroups[index])
                }

                if !failures.isEmpty {
                    failuresSection
                }
            }
        }
    }

    /// Озвучки, у которых есть хотя бы один источник: пустые группы не рисуем —
    /// заголовок без содержимого только мешает.
    private var visibleGroups: [(type: EpisodeType, sources: [EpisodeSource])] {
        sourcesByType.filter { !$0.sources.isEmpty }
    }

    /// Пояснение к группировке: без него непонятно, при чём тут озвучки.
    private var hint: some View {
        Text("У каждой озвучки свои плееры. Выберите источник — страница релиза откроет его серии.")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(Theme.accent)

            Text("Загружаем источники…")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)

            Text("Источники не загрузились")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("Проверьте подключение и откройте экран ещё раз")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button("Закрыть") {
                dismiss()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Озвучка и её источники

    /// Озвучка и её источники: заголовок типа и карточка со строками плееров.
    private func typeSection(_ group: (type: EpisodeType, sources: [EpisodeSource])) -> some View {
        let sources = orderedSources(group.sources)
        return VStack(alignment: .leading, spacing: 8) {
            typeHeader(group.type)

            VStack(spacing: 0) {
                ForEach(sources.indices, id: \.self) { index in
                    sourceRow(sources[index], type: group.type)

                    if index < sources.count - 1 {
                        Divider()
                            .overlay(Theme.separator)
                            .padding(.leading, 12)
                    }
                }
            }
            .cardSurface()
        }
    }

    /// Заголовок озвучки: имя и значок субтитров у субтитровых озвучек.
    private func typeHeader(_ type: EpisodeType) -> some View {
        HStack(spacing: 6) {
            Text(type.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            if type.isSub == true {
                Image(systemName: "captions.bubble")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Субтитры")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    /// Строка источника: у пустого (`episodesCount == 0`) кнопки нет — серий
    /// в нём не будет, поэтому и выбирать нечего.
    @ViewBuilder
    private func sourceRow(_ source: EpisodeSource, type: EpisodeType) -> some View {
        if isEmptySource(source) {
            rowContent(source, type: type, empty: true)
        } else {
            Button {
                onPick(type, source)
            } label: {
                rowContent(source, type: type, empty: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Выбрать источник \(source.displayName)")
        }
    }

    /// Содержимое строки: имя провайдера, счётчик серий и отметка текущего источника.
    private func rowContent(_ source: EpisodeSource, type: EpisodeType, empty: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(empty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)

                if let subtitle = countText(source) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 8)

            if isSelected(source, type: type) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else if !empty {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Источники без серий и подписи

    /// Источники для показа: сначала с сериями, затем пустые — как в меню секции
    /// «Серии». Порядок внутри групп остаётся серверным.
    private func orderedSources(_ sources: [EpisodeSource]) -> [EpisodeSource] {
        let available = sources.filter { !isEmptySource($0) }
        let empty = sources.filter { isEmptySource($0) }
        return available + empty
    }

    /// Источник без серий: сервер отдаёт его наравне с рабочими, а список серий пуст.
    private func isEmptySource(_ source: EpisodeSource) -> Bool {
        source.episodesCount == 0
    }

    /// Источник сейчас выбран на странице релиза.
    private func isSelected(_ source: EpisodeSource, type: EpisodeType) -> Bool {
        type.id == selectedTypeId && source.id == selectedSourceId
    }

    /// Подпись счётчика: «104 серии», «1 серия»; у пустого — «(нет серий)».
    /// `nil` (сервер не прислал счётчик) — без подписи, но строка остаётся кнопкой.
    private func countText(_ source: EpisodeSource) -> String? {
        guard let count = source.episodesCount else { return nil }
        return count > 0 ? episodesText(count) : "(нет серий)"
    }

    /// Русская форма слова «серия»: 1 серия, 2 серии, 5 серий.
    private func episodesText(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "серия"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "серии"
        } else {
            word = "серий"
        }
        return "\(count) \(word)"
    }

    /// Озвучки, которые не удалось загрузить: текст ошибки виден в шите.
    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Не удалось загрузить источники")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)

            ForEach(failures, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }
}
