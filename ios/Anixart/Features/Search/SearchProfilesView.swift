import SwiftUI

// MARK: - Модель экрана

/// Поиск по пользователям: дебаунс при вводе и постраничная подгрузка результатов.
@MainActor
final class SearchProfilesViewModel: ObservableObject {
    @Published private(set) var results: [ProfileBrief] = []
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

    /// Сколько всего пользователей нашлось. Поиск отдаёт `total_count`,
    /// но `total_page_count` у него нулевой, поэтому число страниц считаем сами.
    private var totalCount: Int?

    /// Размер страницы, который вернул сервер (25 пользователей).
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
            let page = try await api.searchProfiles(text, page: 1)
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
            let page = try await api.searchProfiles(query, page: nextPage)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            // Сервер иногда повторяет пользователей между страницами — дубликаты не нужны.
            let loadedIds = Set(results.map { $0.id })
            results += page.content.filter { !loadedIds.contains($0.id) }
            updatePagination(with: page, requestedPage: nextPage)
        } catch is CancellationError {
            return
        } catch {
            // Ошибку подгрузки не показываем поверх уже найденных пользователей.
        }
    }

    /// Раскладывает ответ сервера по страницам. `total_page_count` в поиске
    /// приходит нулевым, поэтому, если он неизвестен, считаем страницы по `total_count`.
    private func updatePagination(with page: Paged<ProfileBrief>, requestedPage: Int) {
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
            // Сервер не сообщил размер списка — пробуем следующую страницу.
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

// MARK: - Экран поиска пользователей

/// Сегмент поиска по пользователям: навигацию и строку поиска предоставляет
/// родительский `SearchView`, а вертикальной прокруткой результатов
/// занимается сам экран.
struct SearchProfilesView: View {
    let query: String

    @StateObject private var model = SearchProfilesViewModel()

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
            placeholder("Введите имя пользователя", systemImage: "person.crop.circle")
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
                placeholder("Никого не нашли", systemImage: "person.crop.circle.badge.questionmark")
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
        LazyVStack(spacing: 8) {
            ForEach(model.results) { profile in
                NavigationLink {
                    UserProfileView(userId: profile.id)
                } label: {
                    SearchProfileRow(profile: profile)
                }
                .buttonStyle(.plain)
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
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Строка пользователя

private struct SearchProfileRow: View {
    let profile: ProfileBrief

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 5) {
                nameLine

                if let badgeName = profile.badgeName, !badgeName.isEmpty {
                    badge(badgeName)
                }
            }

            Spacer(minLength: 8)

            if profile.isOnline == true {
                onlineMark
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Аватар 44x44. Если картинки нет — кружок с первой буквой логина.
    private var avatar: some View {
        ZStack {
            if let avatar = profile.avatar, !avatar.isEmpty {
                RemoteImage(urlString: avatar, contentMode: .fill)
            } else {
                Theme.surfaceHigh

                Text(initial)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
    }

    private var nameLine: some View {
        HStack(spacing: 5) {
            Text(profile.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            if profile.isVerified == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.accentSoft, in: Capsule())
    }

    private var onlineMark: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: 0x34C759))
                .frame(width: 7, height: 7)

            Text("онлайн")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color(hex: 0x34C759))
        }
    }

    private var initial: String {
        let login = profile.login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = login.isEmpty ? profile.displayName : login
        return String(source.prefix(1)).uppercased()
    }
}
