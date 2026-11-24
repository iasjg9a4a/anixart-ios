import SwiftUI

// MARK: - Модель экрана

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var items: [Release] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPage = 1
    @Published private(set) var totalPages = 1
    /// Первая страница показана из офлайн-кэша: сети нет, но снимок сохранился.
    @Published private(set) var isShowingCachedData = false
    /// Удалили последнюю запись страницы и догружаем следующую: пока идёт запрос,
    /// экран показывает индикатор, а не «История пуста».
    @Published private(set) var isRecoveringPage = false

    /// Первая загрузка завершилась: до этого показываем индикатор, а не «История пуста».
    private(set) var hasLoaded = false

    /// id записей, удаление которых сейчас в полёте: повторный свайп не отправит
    /// второй запрос и не покажет ложную ошибку.
    private var deletingIds: Set<Int> = []

    private let api = APIClient.shared

    var canLoadMore: Bool {
        currentPage < totalPages && !isLoading
    }

    func loadFirstPage() async {
        guard !isLoading, !isLoadingMore else { return }

        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let page = try await api.history(page: 1)
            items = page.content
            currentPage = page.currentPage ?? 1
            // Если сервер не прислал `total_page_count`, других страниц не ждём.
            totalPages = page.totalPageCount ?? currentPage
            if page.content.isEmpty {
                totalPages = currentPage
            }
            isShowingCachedData = false

            await OfflineIntegration.storeHistory(page.content,
                                                  page: 1,
                                                  totalCount: page.totalCount,
                                                  totalPageCount: page.totalPageCount)
        } catch {
            errorMessage = error.localizedDescription

            // Без сети показываем последний сохранённый снимок истории.
            // Уже загруженный список (неудачное обновление) не трогаем.
            if items.isEmpty, let cached = await OfflineIntegration.cachedHistory(page: 1) {
                items = cached
                currentPage = 1
                totalPages = 1   // Офлайн листать нечего.
                isShowingCachedData = true
            } else {
                isShowingCachedData = false
            }
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, canLoadMore else { return }

        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        let nextPage = currentPage + 1
        do {
            let page = try await api.history(page: nextPage)

            // Сервер может повторно прислать уже показанные релизы — пропускаем их.
            let knownIds = Set(items.map(\.id))
            let fresh = page.content.filter { !knownIds.contains($0.id) }
            items.append(contentsOf: fresh)

            currentPage = page.currentPage ?? nextPage
            if let total = page.totalPageCount {
                totalPages = total
            }
            // Пустая или состоящая из дублей страница — листать больше нечего.
            if fresh.isEmpty {
                totalPages = currentPage
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Убрать запись из истории: серверный вызов, затем локальное удаление из массива.
    ///
    /// Ошибку пробрасываем наверх — экран покажет её алертом, а строка останется
    /// на месте: если сервер запрос не принял, список не должен с ним расходиться.
    func delete(_ release: Release) async throws {
        guard !deletingIds.contains(release.id) else { return }
        deletingIds.insert(release.id)
        defer { deletingIds.remove(release.id) }

        try await api.historyDelete(releaseId: release.id)
        items.removeAll { $0.id == release.id }

        // Удаление опустошило страницу, но дальше записи ещё есть: подтягиваем
        // следующую, иначе экран показал бы «История пуста» при непустой истории.
        if items.isEmpty, canLoadMore {
            isRecoveringPage = true
            await loadMore()
            isRecoveringPage = false
        }
    }
}

// MARK: - Экран

struct HistoryView: View {
    @StateObject private var model = HistoryViewModel()

    /// Ошибка удаления записи. Отдельный канал от `model.errorMessage`: сбой удаления
    /// не меняет состояние списка, а показывается алертом поверх него.
    @State private var deletionError: String?

    var body: some View {
        NavigationStack {
            content
                .screenBackground()
                .refreshable { await model.loadFirstPage() }
                .navigationTitle("История")
                .navigationBarTitleDisplayMode(.large)
                .task { await model.loadFirstPage() }
                .alert("Не удалось удалить запись", isPresented: isDeletionErrorPresented) {
                    Button("ОК", role: .cancel) {}
                } message: {
                    Text(deletionError ?? "Попробуйте ещё раз.")
                }
        }
    }

    /// Есть записи — показываем список, иначе состояние загрузки/ошибки/пустоты.
    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            ScrollView {
                stateContent
                    .padding(.vertical, 12)
            }
        } else {
            historyList
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if !model.hasLoaded || model.isLoading || model.isRecoveringPage {
            LoadingView()
                .frame(height: 400)
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await model.loadFirstPage() }
            }
            .frame(height: 400)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)

            Text("История пуста")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Смотрите серии под своим аккаунтом — они появятся здесь")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    // MARK: - Список

    /// Свайп-удаление живёт только в `List` (`.swipeActions` в `LazyVStack` не работает),
    /// поэтому rows переехали в плоский список. Оформление прежнее: тот же фон, без
    /// разделителей, те же отступы — см. `historyListRow()`.
    ///
    /// Стенд typecheck'а (`tools/StubSwiftUI`) не моделирует ни `List`, ни
    /// `.swipeActions`, поэтому для него остаётся прежний ScrollView+LazyVStack:
    /// привычный приём из `PlayerWebView` — прятать несовместимый с заглушкой код
    /// за `canImport`. Разметка строки общая (`historyRow`), расходятся только контейнеры.
    @ViewBuilder
    private var historyList: some View {
        #if canImport(SwiftUI)
        List {
            if model.isShowingCachedData {
                OfflineDataBadge()
                    .historyListRow()
            }

            ForEach(model.items) { release in
                historyRow(release)
                    .historyListRow()
                    .historySwipeDelete { delete(release) }
            }

            if let message = model.errorMessage {
                historyErrorFooter(message)
                    .historyListRow()
            }

            if model.canLoadMore {
                loadMoreButton
                    .historyListRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.isShowingCachedData {
                    OfflineDataBadge()
                }

                ForEach(model.items) { release in
                    historyRow(release)
                }

                if let message = model.errorMessage {
                    historyErrorFooter(message)
                }

                if model.canLoadMore {
                    loadMoreButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        #endif
    }

    private func historyRow(_ release: Release) -> some View {
        NavigationLink {
            ReleaseView(releaseId: release.id)
        } label: {
            HistoryRow(release: release)
        }
        .buttonStyle(.plain)
    }

    /// Ошибка подгрузки ниже не должна прятать уже показанную историю.
    private func historyErrorFooter(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)

            Button("Повторить") {
                Task {
                    if model.canLoadMore {
                        await model.loadMore()
                    } else {
                        await model.loadFirstPage()
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(Theme.accent)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingMore)
    }

    // MARK: - Удаление

    /// Свайп «Удалить»: без отдельного подтверждения (жест осознанный, к тому же
    /// `allowsFullSwipe: false`), локальный список правится только после успеха сервера.
    private func delete(_ release: Release) {
        Task { @MainActor in
            do {
                try await model.delete(release)
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }

    /// Алерт удаления: закрывается и кнопкой, и свайпом — состояние чистим в обоих случаях.
    private var isDeletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in
                if !isPresented {
                    deletionError = nil
                }
            }
        )
    }
}

// MARK: - Строка истории

private struct HistoryRow: View {
    let release: Release

    private var genresText: String {
        release.genreList.prefix(2).joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            poster

            VStack(alignment: .leading, spacing: 4) {
                Text(release.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !genresText.isEmpty {
                    Text(genresText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let position = release.lastViewEpisode?.position {
                    Text("Серия \(position)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var poster: some View {
        RemoteImage(urlString: release.image)
            .frame(width: 52, height: 74)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
    }
}

// MARK: - Модификаторы строк `List` и свайп-удаление

private extension View {
    /// Оформление строки `List` «как раньше»: прозрачный фон, без разделителей и
    /// с теми же отступами, что были у `LazyVStack` (16 по бокам, 10 между строками).
    /// Вне `List` — no-op.
    func historyListRow() -> some View {
        #if canImport(SwiftUI)
        return listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        #else
        return self
        #endif
    }

    /// Свайп влево по строке — удалить запись из истории.
    /// `allowsFullSwipe: false`: случайный размашистый жест не должен стирать запись.
    func historySwipeDelete(_ action: @escaping () -> Void) -> some View {
        #if canImport(SwiftUI)
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: action) {
                Label("Удалить", systemImage: "trash")
            }
        }
        #else
        return self
        #endif
    }
}
