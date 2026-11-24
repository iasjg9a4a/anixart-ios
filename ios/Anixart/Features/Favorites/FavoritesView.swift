import SwiftUI

// MARK: - Модель экрана

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published private(set) var items: [Release] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    /// Номера страниц сервер отдаёт сам: на них опирается «Показать ещё».
    @Published private(set) var currentPage: Int = 0
    @Published private(set) var totalPages: Int = 0
    /// Сетка опустела после удаления и догружается следующая страница: пока идёт
    /// запрос, экран показывает индикатор, а не «В избранном пока пусто».
    @Published private(set) var isRecoveringPage = false

    /// id карточек, удаление которых сейчас в полёте: повторное нажатие не отправит
    /// второй запрос и не покажет ложную ошибку.
    private var deletingIds: Set<Int> = []

    private let api = APIClient.shared

    /// Есть ли следующая страница. Пока сервер не ответил, считаем, что страница одна.
    var canLoadMore: Bool { currentPage < totalPages }

    func loadFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await api.favorites(page: 1)
            guard !Task.isCancelled else { return }
            items = page.content
            currentPage = page.currentPage ?? 1
            totalPages = page.totalPageCount ?? 1
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }

        let nextPage = currentPage + 1
        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        do {
            let page = try await api.favorites(page: nextPage)
            guard !Task.isCancelled else { return }
            // Сервер иногда отдаёт уже загруженный релиз — в сетке дубликатам не место.
            let loadedIds = Set(items.map { $0.id })
            items += page.content.filter { !loadedIds.contains($0.id) }
            currentPage = page.currentPage ?? nextPage
            totalPages = page.totalPageCount ?? totalPages
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Убрать релиз из избранного: серверный вызов, затем локальное удаление из массива.
    ///
    /// Ошибку пробрасываем наверх — экран покажет её алертом, а карточка останется
    /// в сетке: если сервер запрос не принял, список не должен с ним расходиться.
    func remove(_ release: Release) async throws {
        guard !deletingIds.contains(release.id) else { return }
        deletingIds.insert(release.id)
        defer { deletingIds.remove(release.id) }

        try await api.removeFromFavorites(releaseId: release.id)
        items.removeAll { $0.id == release.id }

        // Сетка опустела, но дальше избранное ещё есть: подтягиваем следующую страницу,
        // иначе экран показал бы «В избранном пока пусто» при непустом избранном.
        if items.isEmpty, canLoadMore {
            isRecoveringPage = true
            await loadMore()
            isRecoveringPage = false
        }
    }
}

// MARK: - Алерты экрана

/// Один канал сообщений вместо двух параллельных `.alert`: подтверждение удаления
/// и ошибка запроса — взаимоисключающие состояния одной карточки/запроса.
private enum FavoritesAlert {
    case deletionConfirmation(Release)
    case deletionFailed(String)
}

// MARK: - Экран избранного

struct FavoritesView: View {
    @StateObject private var model = FavoritesViewModel()

    /// Карточка, которую удаляем: подтверждение показывается алертом, а сам запрос
    /// уходит только после нажатия «Удалить».
    @State private var alert: FavoritesAlert?

    /// Две колонки, как в поиске: постер 150 pt читается и на iPhone SE, и на Pro Max.
    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Избранное")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await model.loadFirstPage() }
            .task { await model.loadFirstPage() }
            .alert(alertTitle, isPresented: isAlertPresented) {
                if case .deletionConfirmation(let release)? = alert {
                    Button("Удалить", role: .destructive) {
                        delete(release)
                    }
                }

                if case .deletionFailed? = alert {
                    Button("ОК", role: .cancel) {}
                } else {
                    Button("Отмена", role: .cancel) {}
                }
            } message: {
                Text(alertText)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRecoveringPage || (model.isLoading && model.items.isEmpty) {
            LoadingView()
                .frame(height: 320)
        } else if let message = model.errorMessage, model.items.isEmpty {
            ErrorStateView(message: message) {
                Task { await model.loadFirstPage() }
            }
            .frame(height: 320)
        } else if model.items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 14) {
                grid
                footer
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(model.items) { release in
                favoriteCard(release)
            }
        }
    }

    private func favoriteCard(_ release: Release) -> some View {
        NavigationLink {
            ReleaseView(releaseId: release.id)
        } label: {
            ReleaseCard(release: release, posterWidth: 150)
        }
        .buttonStyle(.plain)
        .favoritesDeleteMenu {
            alert = .deletionConfirmation(release)
        }
    }

    @ViewBuilder
    private var footer: some View {
        // Ошибка подгрузки ниже не должна прятать уже показанное избранное.
        if let message = model.errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }

        if model.canLoadMore {
            loadMoreButton
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)

            Text("В избранном пока пусто")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Добавляйте релизы в избранное — они появятся здесь и будут под рукой.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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

    // MARK: - Удаление из избранного

    /// Подтверждённое удаление: сначала спрашиваем (долгое нажатие на карточке),
    /// список правим только после успеха сервера, ошибку — в общий алерт.
    private func delete(_ release: Release) {
        Task { @MainActor in
            do {
                try await model.remove(release)
            } catch {
                alert = .deletionFailed(error.localizedDescription)
            }
        }
    }

    private var alertTitle: LocalizedStringKey {
        switch alert {
        case .deletionConfirmation?:
            return "Удалить из избранного?"
        case .deletionFailed?:
            return "Не удалось удалить"
        case nil:
            return ""
        }
    }

    private var alertText: String {
        switch alert {
        case .deletionConfirmation(let release):
            return "«\(release.displayTitle)» пропадёт из избранного."
        case .deletionFailed(let message):
            return message
        case nil:
            return "Попробуйте ещё раз."
        }
    }

    /// Алерт: закрывается кнопкой и свайпом — состояние чистим в обоих случаях.
    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { isPresented in
                if !isPresented {
                    alert = nil
                }
            }
        )
    }
}

// MARK: - Контекстное меню удаления

private extension View {
    /// Долгое нажатие на карточку — «Удалить из избранного» с подтверждением.
    ///
    /// Стенд typecheck'а (`tools/StubSwiftUI`) `contextMenu` не моделирует, поэтому
    /// там меню не добавляется — как блоки за `canImport` в `PlayerWebView`.
    func favoritesDeleteMenu(_ action: @escaping () -> Void) -> some View {
        #if canImport(SwiftUI)
        return contextMenu {
            Button(role: .destructive, action: action) {
                Label("Удалить из избранного", systemImage: "heart.slash")
            }
        }
        #else
        return self
        #endif
    }
}
