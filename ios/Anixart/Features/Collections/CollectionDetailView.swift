import SwiftUI

// MARK: - Модель экрана

/// Состояние экрана коллекции: шапка коллекции и постраничная сетка релизов.
@MainActor
final class CollectionDetailViewModel: ObservableObject {
    let collectionId: Int

    @Published private(set) var collection: Collection?
    @Published private(set) var releases: [Release] = []

    /// Счётчики статусов из ответа `collection/{id}`: сервер отдаёт их рядом с коллекцией.
    /// В шапке показываются только ненулевые (см. `statusItems` во вью).
    @Published private(set) var watchingCount: Int?
    @Published private(set) var planCount: Int?
    @Published private(set) var completedCount: Int?
    @Published private(set) var holdOnCount: Int?
    @Published private(set) var droppedCount: Int?

    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    /// Нумерация страниц у сервера начинается с единицы, поэтому до загрузки здесь ноль.
    @Published private(set) var currentPage = 0
    @Published private(set) var totalPages = 0

    private let api = APIClient.shared

    init(collectionId: Int) {
        self.collectionId = collectionId
    }

    /// Пока первая страница не загружена, листать нечего: `totalPages` равен нулю.
    var canLoadMore: Bool { currentPage < totalPages }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Шапка и первая страница независимы, поэтому запрашиваем их параллельно.
            async let detailsTask = api.collection(id: collectionId)
            async let releasesTask = api.collectionReleases(id: collectionId, page: 1)

            let details = try await detailsTask
            let page = try await releasesTask

            collection = details.collection
            watchingCount = details.watchingCount
            planCount = details.planCount
            completedCount = details.completedCount
            holdOnCount = details.holdOnCount
            droppedCount = details.droppedCount
            releases = page.content
            applyPagination(page, requestedPage: 1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        let nextPage = currentPage + 1
        do {
            let page = try await api.collectionReleases(id: collectionId, page: nextPage)
            releases.append(contentsOf: page.content)
            applyPagination(page, requestedPage: nextPage)

            // Пустая страница означает конец списка, даже если `total_page_count` обещает больше.
            if page.content.isEmpty {
                totalPages = max(currentPage, 1)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPagination(_ page: Paged<Release>, requestedPage: Int) {
        currentPage = max(page.currentPage ?? requestedPage, requestedPage)

        if let pages = page.totalPageCount, pages > 0 {
            totalPages = max(pages, currentPage)
        } else {
            // Без `total_page_count` следующей страницы не ждём: сервер уже ответил.
            totalPages = max(currentPage, 1)
        }
    }
}

// MARK: - Экран

struct CollectionDetailView: View {
    let collectionId: Int

    @StateObject private var model: CollectionDetailViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    init(collectionId: Int) {
        self.collectionId = collectionId
        _model = StateObject(wrappedValue: CollectionDetailViewModel(collectionId: collectionId))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
            .screenBackground()
            .refreshable { await model.load() }
            .navigationTitle(model.collection?.displayTitle ?? "Коллекция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    shareButton
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let collection = model.collection {
            VStack(alignment: .leading, spacing: 18) {
                header(collection)
                releasesSection
            }
        } else if model.isLoading || model.errorMessage == nil {
            // Первая загрузка (в том числе до старта `.task`): скелетоны вместо спиннера.
            skeleton
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        }
    }

    // MARK: - Шапка

    private func header(_ collection: Collection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cover(collection)

            VStack(alignment: .leading, spacing: 8) {
                Text(collection.displayTitle)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let text = collection.description, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(statsText(collection))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)

            if !statusItems.isEmpty {
                statusRow
            }
        }
    }

    /// Обложка-баннер: во всю ширину, высота 200, скруглённые углы.
    private func cover(_ collection: Collection) -> some View {
        RemoteImage(urlString: collection.image)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
            .padding(.horizontal, 16)
    }

    private func statsText(_ collection: Collection) -> String {
        let releasesCount = collection.releaseCount ?? model.releases.count
        let favoritesCount = collection.favoritesCount ?? 0
        return "\(releasesCount) релизов · \(favoritesCount) в избранном"
    }

    /// Строка-статистика статусов: только ненулевые счётчики с иконками.
    /// Широкий набор не помещается на узких экранах, поэтому — горизонтальная прокрутка.
    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(statusItems) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)

                        Text("\(item.title) \(item.value)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var statusItems: [CollectionStatusItem] {
        let items = [
            CollectionStatusItem(id: "watching", icon: "play.circle.fill",
                                 title: "Смотрю", value: model.watchingCount ?? 0),
            CollectionStatusItem(id: "plan", icon: "clock.fill",
                                 title: "В планах", value: model.planCount ?? 0),
            CollectionStatusItem(id: "completed", icon: "checkmark.circle.fill",
                                 title: "Просмотрено", value: model.completedCount ?? 0),
            CollectionStatusItem(id: "holdOn", icon: "pause.circle.fill",
                                 title: "Отложено", value: model.holdOnCount ?? 0),
            CollectionStatusItem(id: "dropped", icon: "xmark.circle.fill",
                                 title: "Брошено", value: model.droppedCount ?? 0)
        ]
        return items.filter { $0.value > 0 }
    }

    // MARK: - Поделиться

    /// Кнопка шаринга появляется, когда название коллекции уже загружено.
    @ViewBuilder
    private var shareButton: some View {
        if let collection = model.collection {
            ShareLink(item: shareText(for: collection)) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Поделиться коллекцией")
        }
    }

    private func shareText(for collection: Collection) -> String {
        "Коллекция «\(collection.displayTitle)» на Anixart: https://anixart.link/collection/\(collection.id)"
    }

    // MARK: - Скелетоны первой загрузки

    /// Шапка и сетка из скелетонов той же геометрии, что у настоящего контента.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBlock(height: 200, cornerRadius: Theme.radius)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 220, height: 20, cornerRadius: 6)
                    SkeletonBlock(height: 12)
                    SkeletonBlock(width: 180, height: 12)
                    SkeletonBlock(width: 250, height: 26, cornerRadius: 13)
                }
                .padding(.horizontal, 16)
            }

            SkeletonBlock(width: 96, height: 18, cornerRadius: 5)
                .padding(.horizontal, 16)

            SkeletonGrid()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Релизы

    private var releasesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Релизы")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            if model.releases.isEmpty {
                emptyReleases
            } else {
                grid

                if let message = model.errorMessage {
                    inlineError(message)
                }

                if model.canLoadMore {
                    loadMoreButton
                }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(model.releases) { release in
                NavigationLink {
                    ReleaseView(releaseId: release.id)
                } label: {
                    ReleaseCard(release: release, posterWidth: 150)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    /// Релизов нет: объясняем причину и даём кнопку повторной загрузки.
    private var emptyReleases: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)

            Text("В коллекции пока нет релизов")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            Text("Релизы могли ещё не добавить — попробуйте обновить коллекцию.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            Button {
                Task { await model.load() }
            } label: {
                HStack(spacing: 6) {
                    if model.isLoading {
                        ProgressView()
                            .tint(Theme.textPrimary)
                    }

                    Text("Обновить")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(model.isLoading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 32)
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

                Text("Показать ещё")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingMore)
        .padding(.horizontal, 16)
    }

    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Повторить") {
                Task {
                    if model.canLoadMore {
                        await model.loadMore()
                    } else {
                        await model.load()
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface()
        .padding(.horizontal, 16)
    }
}

// MARK: - Счётчик статуса в шапке

/// Один счётчик строки статистики: иконка, подпись и число.
/// Ненулевые элементы собираются в `CollectionDetailView.statusItems`.
private struct CollectionStatusItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let value: Int
}
