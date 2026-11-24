import Foundation
import SwiftUI

// MARK: - Модель экрана
//
// Лента `notification/all/{page}` требует входа: без токена сервер отвечает
// `{"code": 401}`. Поэтому при отсутствии токена запрос не отправляется вовсе,
// а экран сразу объясняет, что нужен аккаунт.

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published private(set) var items: [NotificationItem] = []
    @Published private(set) var unread = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isMarkingRead = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPage = 1
    @Published private(set) var totalPages = 1

    /// id уведомлений, которые сейчас удаляются: у них блокируется кнопка-корзина.
    @Published private(set) var deletingIds: Set<Int> = []

    /// Первая загрузка завершилась: до неё показываем индикатор, а не «Уведомлений нет».
    private(set) var hasLoaded = false

    private let api = APIClient.shared

    /// Признак входа — тот же, что у `Session.isAuthorized` (`TokenStore.shared.token`).
    var isAuthorized: Bool { TokenStore.shared.token != nil }

    var canLoadMore: Bool {
        currentPage < totalPages && !isLoading && !isLoadingMore
    }

    /// Кнопка «Прочитать все» активна, только когда есть что отмечать.
    var canMarkAllRead: Bool {
        isAuthorized && !isMarkingRead && unread > 0
    }

    func load() async {
        guard !isLoading, !isLoadingMore else { return }

        guard isAuthorized else {
            items = []
            unread = 0
            errorMessage = nil
            currentPage = 1
            totalPages = 1
            hasLoaded = true
            return
        }

        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            // Лента и счётчик независимы — грузим их параллельно.
            async let pageTask = api.notifications()
            async let countTask = api.unreadCount()

            let page = try await pageTask
            let count = try? await countTask

            items = page.content
            // Если `notification/count` не ответил, считаем непрочитанные по ленте.
            unread = count ?? page.content.filter { $0.isRead != true }.count
            currentPage = page.currentPage ?? 1
            // Если сервер не прислал `total_page_count`, других страниц не ждём.
            totalPages = page.totalPageCount ?? currentPage
            if page.content.isEmpty {
                totalPages = currentPage
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard isAuthorized, canLoadMore, !isLoading, !isLoadingMore else { return }

        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        let nextPage = currentPage + 1
        do {
            let page = try await api.notifications(page: nextPage)

            // Сервер может повторно прислать уже показанные уведомления — пропускаем.
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

    /// Пометить все уведомления прочитанными (`notification/read`).
    ///
    /// После успеха счётчик обнуляется, элементы ленты помечаются прочитанными
    /// локально — повторно запрашивать список не нужно.
    func markAllRead() async {
        guard isAuthorized, !isMarkingRead else { return }

        isMarkingRead = true
        errorMessage = nil
        defer { isMarkingRead = false }

        do {
            try await api.markAllRead()
            unread = 0
            for index in items.indices where items[index].isRead != true {
                items[index].isNew = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Удалить уведомление (`notification/{тип}/delete/{id}`).
    ///
    /// Тип берётся из самого элемента; для неизвестного типа удаление невозможно,
    /// поэтому такие элементы не удаляются (у них нет кнопки-корзины).
    func delete(_ notification: NotificationItem) async {
        guard isAuthorized, notification.kind != nil,
              !deletingIds.contains(notification.id) else { return }

        deletingIds.insert(notification.id)
        errorMessage = nil
        defer { deletingIds.remove(notification.id) }

        do {
            try await api.delete(notification)
            remove(notification)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ notification: NotificationItem) {
        let wasUnread = notification.isRead != true
        items.removeAll { $0.id == notification.id }
        if wasUnread, unread > 0 {
            unread -= 1
        }
    }
}

// MARK: - Экран

struct NotificationsView: View {
    @StateObject private var model = NotificationsViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.vertical, 12)
            }
            .screenBackground()
            .refreshable { await model.load() }
            .navigationTitle("Уведомления")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    unreadIndicator
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Прочитать все") {
                        Task { await model.markAllRead() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .disabled(!model.canMarkAllRead)
                }
            }
            .task { await model.load() }
        }
    }

    /// Бейдж в шапке: сколько уведомлений ещё не прочитано.
    @ViewBuilder
    private var unreadIndicator: some View {
        if model.unread > 0 {
            Text(model.unread > 99 ? "99+" : "\(model.unread)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .frame(minWidth: 18, minHeight: 18)
                .background(Theme.accent, in: Circle())
                .accessibilityLabel("Непрочитанных уведомлений: \(model.unread)")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAuthorized {
            notAuthorizedState
        } else if !model.hasLoaded || (model.isLoading && model.items.isEmpty) {
            LoadingView()
                .frame(height: 400)
        } else if let message = model.errorMessage, model.items.isEmpty {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        } else if model.items.isEmpty {
            emptyState
        } else {
            notificationsList
        }
    }

    private var notAuthorizedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)

            Text("Войдите, чтобы видеть уведомления")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Откройте раздел «Профиль» и войдите в аккаунт Anixart — ответы, новые серии и заявки в друзья появятся здесь.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)

            Text("Уведомлений нет")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Здесь появятся ответы на комментарии, новые серии и заявки в друзья")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    private var notificationsList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.items) { notification in
                NotificationCard(
                    notification: notification,
                    isDeleting: model.deletingIds.contains(notification.id)
                ) {
                    Task { await model.delete(notification) }
                }
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }

            if model.canLoadMore {
                loadMoreButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 24)
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
}

// MARK: - Карточка уведомления

private struct NotificationCard: View {
    let notification: NotificationItem
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 5) {
                Text(notification.kindTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !detailsText.isEmpty {
                    Text(detailsText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let message = commentMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if !relativeTime.isEmpty {
                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var icon: some View {
        Image(systemName: notification.kindIcon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 38, height: 38)
            .background(Theme.accentSoft, in: Circle())
    }

    /// Справа: синяя точка непрочитанного и корзина (если тип удаляемый).
    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if notification.isRead != true {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Непрочитанное уведомление")
            }

            if notification.kind != nil {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
                .opacity(isDeleting ? 0.4 : 1)
                .accessibilityLabel("Удалить уведомление")
            }
        }
    }

    /// Имя профиля: верхнеуровневое поле `profile` либо автор комментария.
    private var actorName: String? {
        if let name = notification.profile?.displayName, !name.isEmpty {
            return name
        }
        if let name = notification.comment?.profile?.displayName, !name.isEmpty {
            return name
        }
        return nil
    }

    /// Вторая строка: кто и о чём — только поля, которые есть в модели.
    private var detailsText: String {
        var parts: [String] = []
        if let name = actorName {
            parts.append(name)
        }
        if let episode = notification.episode?.name, !episode.isEmpty {
            parts.append(episode)
        }
        if let release = notification.release?.displayTitle, !release.isEmpty {
            parts.append(release)
        }
        return parts.joined(separator: " · ")
    }

    /// Текст комментария (для comment-уведомлений), в одну строку.
    private var commentMessage: String? {
        guard let raw = notification.comment?.message else { return nil }
        let message = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private var relativeTime: String {
        NotificationTime.relative(notification.timestamp)
    }
}

// MARK: - Время уведомления

/// Относительное время: «5 минут назад».
///
/// `RelativeDateTimeFormatter` есть только в Apple Foundation — в Linux-сборке
/// (стенд `tools/StubSwiftUI`) его нет, поэтому для неё запасной абсолютный формат.
private enum NotificationTime {
    static func relative(_ timestamp: Int?) -> String {
        // Сервер отдаёт `timestamp` в миллисекундах.
        guard let timestamp = timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        #if canImport(Darwin)
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
        #else
        return absoluteFormatter.string(from: date)
        #endif
    }

    #if canImport(Darwin)
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter
    }()
    #else
    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter
    }()
    #endif
}

// MARK: - Тип уведомления

private extension NotificationItem {
    /// Иконка `systemImage` для каждого типа уведомления.
    var kindIcon: String {
        switch kind {
        case .friend:
            return status == 1 ? "person.2.fill" : "person.badge.plus"
        case .episode:
            return "play.rectangle.fill"
        case .releaseComment:
            return "bubble.left.fill"
        case .collectionComment:
            return "rectangle.stack.fill"
        case .myCollection:
            return "bubble.left.and.bubble.right.fill"
        case .article:
            return "doc.text.fill"
        case .articleComment:
            return "text.bubble.fill"
        case .myArticle:
            return "arrowshape.turn.up.left.fill"
        case .relatedRelease:
            return "link"
        case nil:
            return "bell.fill"
        }
    }

    /// Описание уведомления: что произошло.
    var kindTitle: String {
        switch kind {
        case .friend:
            return status == 1 ? "Заявка в друзья принята" : "Новая заявка в друзья"
        case .episode:
            return "Новая серия"
        case .releaseComment:
            return "Новый комментарий к релизу"
        case .collectionComment:
            return "Новый комментарий к коллекции"
        case .myCollection:
            return "Ответ на ваш комментарий в коллекции"
        case .article:
            return "Новая статья"
        case .articleComment:
            return "Новый комментарий к статье"
        case .myArticle:
            return "Ответ на ваш комментарий в статье"
        case .relatedRelease:
            return "Новый связанный релиз"
        case nil:
            return "Уведомление"
        }
    }
}
