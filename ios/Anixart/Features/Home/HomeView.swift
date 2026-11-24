import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    /// Полка главной: список релизов (`ShelfView`) или горизонтальный ряд коллекций.
    struct Shelf: Identifiable {
        let id: String
        let title: String
        let releases: [Release]
        let collections: [CollectionBrief]

        init(id: String,
             title: String,
             releases: [Release] = [],
             collections: [CollectionBrief] = []) {
            self.id = id
            self.title = title
            self.releases = releases
            self.collections = collections
        }

        var isCollections: Bool { !collections.isEmpty }
    }

    private enum ShelfID {
        static let watching = "watching"
        static let discussing = "discussing"
        static let recommendations = "recommendations"
        static let collections = "collections"
        static let catalog = "catalog"
    }

    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var isLoading = false
    /// Догрузка следующей страницы каталога: кнопка «Загрузить ещё» показывает спиннер.
    @Published private(set) var isLoadingMore = false
    /// Сервер не отдаёт реальное число страниц каталога, поэтому «есть ещё» — это признак
    /// непустого ответа на последнюю загруженную страницу.
    @Published private(set) var canLoadMoreCatalog = false
    @Published private(set) var errorMessage: String?
    /// Ошибка догрузки каталога: показывается рядом с кнопкой, уже загруженное не прячет.
    @Published private(set) var loadMoreErrorMessage: String?
    /// Полки показаны из офлайн-кэша: сети нет, но последний снимок сохранился.
    @Published private(set) var isShowingCachedData = false

    /// Номер последней загруженной страницы каталога (в приложении страницы с единицы).
    private var catalogPage = 1

    private let api = APIClient.shared

    func load() async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        loadMoreErrorMessage = nil
        defer { isLoading = false }

        do {
            async let discoverTask = api.discover()
            async let catalogTask = api.catalog(page: 1)

            let discover = try await discoverTask
            let catalog = try await catalogTask

            var result: [Shelf] = []
            if let watching = discover.watching, !watching.isEmpty {
                result.append(Shelf(id: ShelfID.watching,
                                    title: "Сейчас смотрят",
                                    releases: uniqueReleases(watching)))
            }
            if let discussing = discover.discussing, !discussing.isEmpty {
                result.append(Shelf(id: ShelfID.discussing,
                                    title: "Обсуждают",
                                    releases: uniqueReleases(discussing)))
            }
            if let recommendations = discover.recommendations, !recommendations.isEmpty {
                result.append(Shelf(id: ShelfID.recommendations,
                                    title: "Рекомендуем",
                                    releases: uniqueReleases(recommendations)))
            }
            if let collections = discover.collections, !collections.isEmpty {
                let unique = uniqueCollections(collections)
                if !unique.isEmpty {
                    result.append(Shelf(id: ShelfID.collections,
                                        title: "Коллекции",
                                        collections: unique))
                }
            }
            if !catalog.content.isEmpty {
                result.append(Shelf(id: ShelfID.catalog,
                                    title: "Новинки каталога",
                                    releases: uniqueReleases(catalog.content)))
            }

            shelves = result
            catalogPage = 1
            canLoadMoreCatalog = !catalog.content.isEmpty
            isShowingCachedData = false

            // Кэшируем только каталог: полки `discover` персональные и устаревают быстрее.
            await OfflineIntegration.storeCatalog(catalog.content,
                                                  page: 1,
                                                  totalCount: catalog.totalCount,
                                                  totalPageCount: catalog.totalPageCount)
        } catch {
            errorMessage = error.localizedDescription
            catalogPage = 1
            canLoadMoreCatalog = false
            loadMoreErrorMessage = nil

            // Сеть недоступна — показываем последний удачный снимок каталога.
            // Если полки уже на экране (обновление не удалось), не подменяем их.
            if shelves.isEmpty, let cached = await OfflineIntegration.cachedCatalog(page: 1) {
                shelves = [Shelf(id: ShelfID.catalog,
                                 title: "Новинки каталога",
                                 releases: uniqueReleases(cached))]
                isShowingCachedData = true
            } else {
                isShowingCachedData = false
            }
        }
    }

    private var catalogShelfIndex: Int? {
        shelves.firstIndex { $0.id == ShelfID.catalog }
    }

    /// Догрузить следующую страницу каталога и дописать её в полку без дублей по `id`.
    ///
    /// `filter/{page}` не отдаёт осмысленный `total_page_count` (сервер присылает 0),
    /// поэтому конец каталога определяется по пустому ответу на запрошенную страницу.
    func loadMoreCatalog() async {
        guard canLoadMoreCatalog, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreErrorMessage = nil
        defer { isLoadingMore = false }

        let nextPage = catalogPage + 1
        do {
            let page = try await api.catalog(page: nextPage)
            catalogPage = max(page.currentPage ?? nextPage, nextPage)
            canLoadMoreCatalog = !page.content.isEmpty

            guard let index = catalogShelfIndex else { return }
            let shelf = shelves[index]
            var seen = Set(shelf.releases.map(\.id))
            let fresh = page.content.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty {
                shelves[index] = Shelf(id: shelf.id,
                                       title: shelf.title,
                                       releases: shelf.releases + fresh)
            }
        } catch {
            // Уже загруженные страницы не прячем: ошибка только рядом с кнопкой.
            loadMoreErrorMessage = error.localizedDescription
        }
    }

    /// Полки `discover` могут пересекаться между собой и внутри страницы — id на экране уникальны.
    private func uniqueReleases(_ releases: [Release]) -> [Release] {
        var seen = Set<Int>()
        return releases.filter { seen.insert($0.id).inserted }
    }

    private func uniqueCollections(_ collections: [CollectionBrief]) -> [CollectionBrief] {
        var seen = Set<Int>()
        return collections.filter { seen.insert($0.id).inserted }
    }
}

struct HomeView: View {
    @StateObject private var model = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.vertical, 12)
            }
            .screenBackground()
            .refreshable { await model.load() }
            .navigationTitle("Anixart")
            .navigationBarTitleDisplayMode(.large)
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.shelves.isEmpty && model.isLoading {
            LoadingView().frame(height: 400)
        } else if let message = model.errorMessage, model.shelves.isEmpty {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        } else {
            LazyVStack(alignment: .leading, spacing: 26) {
                if model.isShowingCachedData {
                    OfflineDataBadge()
                        .padding(.horizontal, 16)
                }

                BannerShelfView()

                ContinueWatchingShelf()

                ForEach(model.shelves) { shelf in
                    if shelf.isCollections {
                        CollectionBriefShelfView(title: shelf.title,
                                                 collections: shelf.collections)
                    } else {
                        ShelfView(title: shelf.title, releases: shelf.releases)
                    }
                }

                catalogFooter
            }
        }
    }

    /// Подвал полки каталога: «Загрузить ещё» и ошибка догрузки (если была).
    @ViewBuilder
    private var catalogFooter: some View {
        if model.canLoadMoreCatalog {
            Button {
                Task { await model.loadMoreCatalog() }
            } label: {
                HStack(spacing: 8) {
                    if model.isLoadingMore {
                        ProgressView()
                            .tint(Theme.accent)
                    }

                    Text("Загрузить ещё")
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

        if let message = model.loadMoreErrorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Повторить") {
                    Task { await model.loadMoreCatalog() }
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
}

// MARK: - Полка коллекций

/// Горизонтальный ряд карточек коллекций из `discover/hub` → `collections`.
private struct CollectionBriefShelfView: View {
    let title: String
    let collections: [CollectionBrief]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(collections) { collection in
                        NavigationLink {
                            CollectionDetailView(collectionId: collection.id)
                        } label: {
                            CollectionBriefCard(collection: collection)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Карточка коллекции

private struct CollectionBriefCard: View {
    let collection: CollectionBrief

    /// Обложка 16:9 при высоте 120 — ряд карточек выглядит ровно.
    private let coverWidth: CGFloat = 120 * 16 / 9
    private let coverHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(urlString: collection.image)
                .frame(width: coverWidth, height: coverHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .stroke(Theme.separator, lineWidth: 1)
                )

            Text(collection.displayTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: coverWidth, alignment: .leading)

            if let count = collection.releaseCount {
                Text("\(count) релизов")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(width: coverWidth, alignment: .leading)
            }
        }
    }
}
