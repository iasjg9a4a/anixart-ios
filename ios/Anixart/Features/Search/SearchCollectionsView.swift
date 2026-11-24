import SwiftUI

// MARK: - Модель экрана

/// Поиск по коллекциям: дебаунс при вводе и постраничная подгрузка результатов.
@MainActor
final class SearchCollectionsViewModel: ObservableObject {
    @Published private(set) var results: [Collection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var didSearch = false
    @Published private(set) var currentPage: Int = 0
    @Published private(set) var totalPages: Int = 0

    private let api = APIClient.shared

    /// Запрос, по которому показаны результаты: нужен для «Показать ещё».
    private var activeQuery = ""

    /// Номер запуска поиска. Отменённая задача не должна трогать состояние новой.
    private var searchGeneration = 0

    /// Сколько всего коллекций нашлось. Поиск отдаёт `total_count`, но
    /// `total_page_count` у него нулевой, поэтому число страниц считаем сами.
    private var totalCount: Int?

    /// Размер страницы, который вернул сервер (25 коллекций).
    private var pageSize = 0

    /// Есть ли следующая страница. Пока сервер не ответил, считаем, что страница одна.
    var canLoadMore: Bool {
        guard currentPage > 0, currentPage < totalPages else { return false }
        if let totalCount = totalCount {
            return results.count < totalCount
        }
        return true
    }

    func search(query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        searchGeneration += 1
        let generation = searchGeneration

        guard !text.isEmpty else {
            reset()
            return
        }

        activeQuery = text
        isLoading = true
        isLoadingMore = false
        errorMessage = nil

        defer {
            if generation == searchGeneration { isLoading = false }
        }

        // Дебаунс: пока пользователь печатает, запрос на сервер не уходит.
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, generation == searchGeneration else { return }

        do {
            let page = try await api.searchCollections(text, page: 1)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = page.content
            didSearch = true
            updatePagination(with: page, requestedPage: 1)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = []
            currentPage = 0
            totalPages = 0
            totalCount = nil
            pageSize = 0
            didSearch = false
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }

        let query = activeQuery
        guard !query.isEmpty else { return }

        let nextPage = currentPage + 1
        let generation = searchGeneration
        isLoadingMore = true
        defer {
            if generation == searchGeneration { isLoadingMore = false }
        }

        do {
            let page = try await api.searchCollections(query, page: nextPage)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            // Сервер иногда повторяет коллекции между страницами — дубликаты не нужны.
            let loadedIds = Set(results.map { $0.id })
            results += page.content.filter { !loadedIds.contains($0.id) }
            updatePagination(with: page, requestedPage: nextPage)
        } catch is CancellationError {
            return
        } catch {
            // Ошибку подгрузки не показываем поверх уже найденных коллекций.
        }
    }

    /// Раскладывает ответ сервера по страницам. `total_page_count` в поиске
    /// приходит нулевым, поэтому, если он неизвестен, считаем страницы по `total_count`.
    private func updatePagination(with page: Paged<Collection>, requestedPage: Int) {
        let loadedCount = page.content.count

        let serverPage = page.currentPage ?? 0
        currentPage = serverPage > 0 ? serverPage : requestedPage

        if let total = page.totalCount, total >= 0 {
            totalCount = total
        }
        if loadedCount > pageSize {
            pageSize = loadedCount
        }

        // Пустая страница означает конец списка, даже если счётчики сервера говорят иное.
        guard loadedCount > 0 else {
            totalPages = currentPage
            return
        }

        if let serverPages = page.totalPageCount, serverPages > 0 {
            totalPages = max(serverPages, currentPage)
        } else if let total = totalCount, pageSize > 0 {
            totalPages = max((total + pageSize - 1) / pageSize, currentPage)
        } else {
            totalPages = currentPage + 1
        }
    }

    private func reset() {
        results = []
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        didSearch = false
        currentPage = 0
        totalPages = 0
        totalCount = nil
        pageSize = 0
        activeQuery = ""
    }
}

// MARK: - Экран поиска коллекций

/// Экран встраивается в `SearchView` как один из сегментов: навигацию и строку
/// поиска держит родительский экран, а прокрутка у сегмента своя.
struct SearchCollectionsView: View {
    let query: String

    @StateObject private var model = SearchCollectionsViewModel()

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .task(id: query) { await model.search(query: query) }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            placeholder("Введите запрос", systemImage: "magnifyingglass")
        } else if model.isLoading && model.results.isEmpty {
            LoadingView()
                .frame(height: 320)
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await model.search(query: trimmedQuery) }
            }
            .frame(height: 320)
        } else if model.results.isEmpty {
            if model.didSearch {
                placeholder("Ничего не найдено", systemImage: "rectangle.stack")
            } else {
                LoadingView()
                    .frame(height: 320)
            }
        } else {
            resultsList
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resultsList: some View {
        LazyVStack(spacing: 14) {
            ForEach(model.results) { collection in
                SearchCollectionCard(collection: collection)
            }

            if model.canLoadMore {
                loadMoreButton
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await model.loadMore() }
        } label: {
            HStack(spacing: 8) {
                if model.isLoadingMore {
                    ProgressView()
                        .tint(Theme.accent)
                }

                Text(model.isLoadingMore ? "Загрузка…" : "Показать ещё")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingMore)
        .padding(.top, 4)
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Карточка коллекции

private struct SearchCollectionCard: View {
    let collection: Collection

    /// Обложка 16:9 во всю ширину карточки, высота кадра — 140 pt.
    private let coverHeight: CGFloat = 140
    private let coverAspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover

            VStack(alignment: .leading, spacing: 5) {
                Text(collection.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let description = collection.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Text("\(collection.releaseCount ?? 0) релизов")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cover: some View {
        RemoteImage(urlString: collection.image, contentMode: .fill)
            .aspectRatio(coverAspectRatio, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: coverHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
    }
}
