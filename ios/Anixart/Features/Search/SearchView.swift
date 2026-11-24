import SwiftUI

/// Конформанс для `APIClient.catalog(page:filter:)`.
///
/// `ReleaseFilter` уже отдаёт готовые query-параметры, а сам `APIClient` от типа экрана
/// не зависит (слой Core в CI проверяется отдельно от Features), поэтому конформанс
/// объявлен здесь — на стороне экрана.
extension ReleaseFilter: CatalogQueryProviding {}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""

    /// Фильтр каталога. Действует только при пустом запросе; при вводе текста сбрасывается.
    @Published var filter = ReleaseFilter()

    @Published private(set) var results: [Release] = []
    /// Выдача каталога с фильтром — показываем её, пока строка поиска пустая.
    @Published private(set) var catalogResults: [Release] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var catalogErrorMessage: String?
    @Published private(set) var didSearch = false

    private let api = APIClient.shared
    private var lastQuery: String = ""

    init(initialQuery: String = "") {
        query = initialQuery
    }

    /// Каталог (а не поиск) показываем, только пока запрос пустой.
    var isCatalogMode: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Чипы фильтра показываем, только если фильтр отличается от значения по умолчанию.
    var hasActiveFilter: Bool { filter != ReleaseFilter() }

    /// Что сейчас в сетке «Релизов»: каталог с фильтром или результат поиска.
    var displayedReleases: [Release] { isCatalogMode ? catalogResults : results }

    var displayedError: String? { isCatalogMode ? catalogErrorMessage : errorMessage }

    var isBusy: Bool { isCatalogMode ? isLoadingCatalog : isLoading }

    /// Точка входа `.task(id: query)`: пустой запрос — каталог с фильтром, иначе поиск.
    ///
    /// Фильтр относится только к каталогу, поэтому при вводе текста он сбрасывается —
    /// иначе было бы не видно, что фильтр продолжает действовать на выдачу.
    func reload() async {
        if isCatalogMode {
            await loadCatalog()
        } else {
            if filter != ReleaseFilter() {
                filter = ReleaseFilter()
            }
            await search()
        }
    }

    /// Первая страница каталога с текущим фильтром (`GET filter/0` + query-параметры).
    func loadCatalog() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }

        do {
            let page = try await api.catalog(page: 1, filter: filter)
            guard !Task.isCancelled else { return }
            catalogResults = page.content
            catalogErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            catalogResults = []
            catalogErrorMessage = error.localizedDescription
        }
    }

    /// «Применить» из sheet'а фильтров: сохранить фильтр и перезагрузить каталог.
    func applyFilter(_ value: ReleaseFilter) async {
        filter = value
        guard isCatalogMode else { return }
        await loadCatalog()
    }

    /// Сброс одного условия фильтра из чипа над сеткой.
    func resetSort() async {
        var value = filter
        value.sort = .dateUpdate
        await applyFilter(value)
    }

    func resetGenre() async {
        var value = filter
        value.genres = []
        await applyFilter(value)
    }

    func resetYear() async {
        var value = filter
        value.year = nil
        await applyFilter(value)
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count >= 2 else {
            results = []
            didSearch = false
            errorMessage = nil
            lastQuery = ""
            return
        }
        guard text != lastQuery else { return }
        lastQuery = text

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await api.search(text, page: 1)
            guard !Task.isCancelled else { return }
            results = page.content
            didSearch = true
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            results = []
            lastQuery = ""
            errorMessage = error.localizedDescription
        }
    }
}

enum SearchSegment: String, CaseIterable, Identifiable {
    case releases
    case collections
    case profiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .releases: return "Релизы"
        case .collections: return "Коллекции"
        case .profiles: return "Люди"
        }
    }
}

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    @State private var segment: SearchSegment = .releases
    /// Открыт ли sheet фильтров каталога.
    @State private var showsFilters = false

    init(initialQuery: String = "") {
        // Стартовый запрос приходит из deep link (`anixart://search?q=...`).
        _model = StateObject(wrappedValue: SearchViewModel(initialQuery: initialQuery))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(SearchSegment.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch segment {
                case .releases:
                    releasesContent
                case .collections:
                    SearchCollectionsView(query: model.query)
                case .profiles:
                    SearchProfilesView(query: model.query)
                }
            }
            .screenBackground()
            .navigationTitle("Поиск")
            .searchable(text: $model.query, prompt: "Аниме, коллекции, пользователи…")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showsFilterButton {
                        filterButton
                    }
                }
            }
            .sheet(isPresented: $showsFilters) {
                SearchFiltersView(filter: $model.filter) { applied in
                    Task { await model.applyFilter(applied) }
                }
            }
            .task(id: model.query) { await model.reload() }
        }
    }

    // MARK: - Фильтр каталога

    /// Кнопка фильтра — только в «Релизах» и при пустом запросе: фильтр относится к каталогу.
    private var showsFilterButton: Bool {
        segment == .releases && model.isCatalogMode
    }

    private var filterButton: some View {
        Button {
            showsFilters = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - «Релизы»

    @ViewBuilder
    private var releasesContent: some View {
        VStack(spacing: 0) {
            if model.isCatalogMode && model.hasActiveFilter {
                activeFilterChips
            }

            ScrollView {
                releasesGrid
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    /// Чипы активных условий фильтра над сеткой; тап по чипу снимает это условие.
    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.filter.sort != .dateUpdate {
                    filterChip("Сортировка: \(model.filter.sort.title)") {
                        Task { await model.resetSort() }
                    }
                }
                if let genre = model.filter.genres.first {
                    filterChip(genre) {
                        Task { await model.resetGenre() }
                    }
                }
                if let year = model.filter.year {
                    filterChip(String(year)) {
                        Task { await model.resetYear() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .padding(.top, 4)
    }

    private func filterChip(_ title: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var releasesGrid: some View {
        if model.isBusy && model.displayedReleases.isEmpty {
            LoadingView().frame(height: 320)
        } else if let message = model.displayedError {
            ErrorStateView(message: message) {
                Task { await model.reload() }
            }
            .frame(height: 320)
        } else if model.displayedReleases.isEmpty {
            emptyReleasesHint
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(model.displayedReleases) { release in
                    NavigationLink {
                        ReleaseView(releaseId: release.id)
                    } label: {
                        ReleaseCard(release: release, posterWidth: 150)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyReleasesHint: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isCatalogMode ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text(emptyReleasesText)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyReleasesText: String {
        if model.isCatalogMode {
            return model.hasActiveFilter ? "По выбранным фильтрам ничего не найдено" : "Каталог пуст"
        }
        return model.didSearch ? "Ничего не найдено" : "Введите хотя бы два символа"
    }
}
