import Foundation
import SwiftUI

// MARK: - Модель экрана

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published private(set) var friends: [ProfileBrief] = []
    @Published private(set) var requestsIn: [FriendRequest] = []
    @Published private(set) var recommendations: [ProfileBrief] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false

    private let api = APIClient.shared

    /// Три списка грузятся параллельно: сбой одного не мешает остальным.
    func load(profileId: Int) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let friendsTask = fetchFriends(profileId: profileId)
        async let incomingTask = fetchIncoming()
        async let recommendationsTask = fetchRecommendations()

        let loadedFriends = await friendsTask
        let loadedIncoming = await incomingTask
        let loadedRecommendations = await recommendationsTask

        if let loadedFriends { friends = loadedFriends }
        if let loadedIncoming { requestsIn = loadedIncoming }
        if let loadedRecommendations { recommendations = loadedRecommendations }
        hasLoaded = true

        // Общая ошибка — только если не удался ни один запрос. Иначе показываем
        // пустое состояние конкретной секции: закрытый профиль и сбой сети
        // выглядят по-разному.
        if loadedFriends == nil && loadedIncoming == nil && loadedRecommendations == nil {
            errorMessage = "Не удалось загрузить друзей. Проверьте соединение и попробуйте ещё раз."
        }
    }

    /// Принять входящую заявку: `request/send` и перенос профиля в список друзей.
    func accept(_ request: FriendRequest) async {
        let targetId = request.profile?.id ?? request.id
        do {
            try await api.sendRequest(id: targetId)
            requestsIn.removeAll { $0.id == request.id }
            if let profile = request.profile, !friends.contains(where: { $0.id == profile.id }) {
                friends.insert(profile, at: 0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Скрыть входящую заявку: `request/hide`.
    func decline(_ request: FriendRequest) async {
        let targetId = request.profile?.id ?? request.id
        do {
            try await api.hideRequest(id: targetId)
            requestsIn.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Убрать пользователя из друзей: `request/remove`.
    func remove(id: Int) async {
        do {
            try await api.removeRequest(id: id)
            friends.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Запросы

    private func fetchFriends(profileId: Int) async -> [ProfileBrief]? {
        do {
            // Бэкенд нумерует страницы с нуля — первая страница это `page: 0`.
            let page = try await api.friends(profileId: profileId, page: 0)
            return page.content
        } catch {
            return nil
        }
    }

    private func fetchIncoming() async -> [FriendRequest]? {
        do {
            let page = try await api.friendRequestsIn(page: 0)
            return page.content
        } catch {
            return nil
        }
    }

    private func fetchRecommendations() async -> [ProfileBrief]? {
        do {
            return try await api.recommendations() ?? []
        } catch {
            return nil
        }
    }
}

// MARK: - Экран

struct FriendsView: View {
    let profileId: Int

    @StateObject private var model: FriendsViewModel

    init(profileId: Int) {
        self.profileId = profileId
        _model = StateObject(wrappedValue: FriendsViewModel())
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.hasLoaded {
                    LoadingView()
                } else if !hasAnyContent, let message = model.errorMessage {
                    ErrorStateView(message: message) {
                        Task { await model.load(profileId: profileId) }
                    }
                } else if !hasAnyContent {
                    emptyState
                } else {
                    lists
                }
            }
            .screenBackground()
            .navigationTitle("Друзья")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load(profileId: profileId) }
        }
    }

    private var hasAnyContent: Bool {
        !model.friends.isEmpty || !model.requestsIn.isEmpty || !model.recommendations.isEmpty
    }

    // MARK: Списки

    private var lists: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let message = model.errorMessage {
                    errorBanner(message)
                }
                if !model.requestsIn.isEmpty {
                    requestsSection
                }
                friendsSection
                recommendationsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .refreshable { await model.load(profileId: profileId) }
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FriendsSectionHeader(title: "Заявки", count: model.requestsIn.count)

            LazyVStack(spacing: 8) {
                ForEach(model.requestsIn) { request in
                    RequestRow(
                        request: request,
                        onAccept: { Task { await model.accept(request) } },
                        onDecline: { Task { await model.decline(request) } }
                    )
                }
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FriendsSectionHeader(title: "Друзья", count: model.friends.count)

            if model.friends.isEmpty {
                SectionEmptyView(text: "Друзей пока нет. Отправить заявку можно с профиля пользователя.")
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.friends) { profile in
                        NavigationLink {
                            UserProfileView(userId: profile.id)
                        } label: {
                            FriendRow(profile: profile)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FriendsSectionHeader(title: "Возможные друзья", count: model.recommendations.count)

            if model.recommendations.isEmpty {
                SectionEmptyView(text: "Рекомендаций пока нет.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.recommendations) { profile in
                            NavigationLink {
                                UserProfileView(userId: profile.id)
                            } label: {
                                RecommendationCard(profile: profile)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Пустые состояния и ошибка

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)
            Text("Пока пусто")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("У профиля нет друзей, входящих заявок и рекомендаций. Если профиль закрыт, список друзей может быть скрыт настройками приватности.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

// MARK: - Строки списков

private enum FriendsMetrics {
    static let avatarSize: CGFloat = 44
}

private struct FriendAvatar: View {
    let profile: ProfileBrief

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(urlString: profile.avatar)
                .frame(width: FriendsMetrics.avatarSize, height: FriendsMetrics.avatarSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.separator, lineWidth: 1))

            if profile.isOnline == true {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
            }
        }
        .frame(width: FriendsMetrics.avatarSize, height: FriendsMetrics.avatarSize)
    }
}

private struct FriendName: View {
    let profile: ProfileBrief

    var body: some View {
        HStack(spacing: 4) {
            Text(profile.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            if profile.isVerified == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

private struct FriendRow: View {
    let profile: ProfileBrief

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(profile: profile)
            FriendName(profile: profile)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardSurface()
    }
}

private struct RequestRow: View {
    let request: FriendRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let profile = request.profile {
                NavigationLink {
                    UserProfileView(userId: profile.id)
                } label: {
                    HStack(spacing: 10) {
                        FriendAvatar(profile: profile)
                        FriendName(profile: profile)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text("Заявка в друзья")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onAccept) {
                Text("Принять")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onDecline) {
                Text("Скрыть")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceHigh, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardSurface()
    }
}

private struct RecommendationCard: View {
    let profile: ProfileBrief

    var body: some View {
        VStack(spacing: 8) {
            FriendAvatar(profile: profile)
            FriendName(profile: profile)
            Text(profile.isOnline == true ? "В сети" : "Не в сети")
                .font(.caption2)
                .foregroundStyle(profile.isOnline == true ? Color.green : Theme.textTertiary)
        }
        .frame(width: 108)
        .padding(.vertical, 12)
        .cardSurface()
    }
}

// MARK: - Заголовок секции и пустая секция

private struct FriendsSectionHeader: View {
    let title: String
    var count: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct SectionEmptyView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cardSurface()
    }
}
