import SwiftUI

@MainActor
final class CollectionsViewModel: ObservableObject {
    /// Полка экрана «Коллекции»: заголовок и подборки под ним.
    struct Shelf: Identifiable {
        let id: String
        let title: String
        let collections: [CollectionBrief]
    }

    @Published private(set) var shelves: [Shelf] = []

    /// Общий список коллекций для вертикальной сетки (эндпоинт `collection/all`).
    @Published private(set) var allCollections: [CollectionBrief] = []

    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = APIClient.shared

    /// Пусто и на полках, и в сетке — значит показывать заглушку.
    var isEmpty: Bool { shelves.isEmpty && allCollections.isEmpty }

    func load() async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Хаб и общий список независимы, поэтому грузим их параллельно.
            async let hubTask = api.collectionsHub()
            async let allTask = api.collections(page: 1)

            let hub = try await hubTask
            let page = try await allTask

            var result: [Shelf] = []
            if let weekly = hub.weekly, !weekly.isEmpty {
                result.append(Shelf(id: "weekly", title: "Коллекции недели", collections: weekly))
            }
            if let recommended = hub.recommended, !recommended.isEmpty {
                result.append(Shelf(id: "recommended", title: "Рекомендуем", collections: recommended))
            }
            if let mine = hub.my, !mine.isEmpty {
                result.append(Shelf(id: "my", title: "Мои коллекции", collections: mine))
            }

            shelves = result
            allCollections = page.content
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CollectionsView: View {
    @StateObject private var model = CollectionsViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.vertical, 12)
            }
            .screenBackground()
            .refreshable { await model.load() }
            .navigationTitle("Коллекции")
            .navigationBarTitleDisplayMode(.large)
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.isEmpty {
            loadingSkeleton
        } else if let message = model.errorMessage, model.isEmpty {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        } else if model.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(model.shelves) { shelf in
                    CollectionShelf(shelf: shelf)
                }
                if !model.allCollections.isEmpty {
                    allCollectionsSection
                }
            }
        }
    }

    /// Первая загрузка: отступы повторяют настоящие полки и сетку «Все коллекции».
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            SkeletonShelf(items: 4)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(width: 140, height: 16, cornerRadius: 5)
                    .padding(.horizontal, 16)

                SkeletonGrid(items: 6)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var allCollectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Все коллекции")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(model.allCollections) { collection in
                    NavigationLink {
                        CollectionDetailView(collectionId: collection.id)
                    } label: {
                        CollectionCard(collection: collection)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("Коллекций пока нет")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Полка

private struct CollectionShelf: View {
    let shelf: CollectionsViewModel.Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.collections) { collection in
                        NavigationLink {
                            CollectionDetailView(collectionId: collection.id)
                        } label: {
                            CollectionCard(collection: collection)
                                .frame(width: 172)
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
//
// Звезды избранного на карточке нет: экран работает с `CollectionBrief`, а в нём
// нет `is_favorite` (только id/title/image/release_count). Поле добавляется лишь
// в Models.swift, который эта правка не трогает, поэтому кнопку не показываем —
// не выдумываем состояние. Тумблер вешается на полную `Collection`
// (`CollectionDetailView`) через `APIClient.addCollectionFavorite/removeCollectionFavorite`.

private struct CollectionCard: View {
    let collection: CollectionBrief

    /// Обложка у всех карточек одной высоты — полка и сетка выглядят ровно.
    private let coverHeight: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover

            Text(collection.displayTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let count = collection.releaseCount {
                Text("\(count) релизов")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var cover: some View {
        RemoteImage(urlString: collection.image)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .frame(height: coverHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
    }
}
