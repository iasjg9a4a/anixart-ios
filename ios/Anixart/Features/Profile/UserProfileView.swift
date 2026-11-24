import Foundation
import SwiftUI

// MARK: - Модель экрана

@MainActor
final class UserProfileViewModel: ObservableObject {
    let userId: Int

    @Published private(set) var profile: Profile?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = APIClient.shared

    init(userId: Int) {
        self.userId = userId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            profile = try await api.profile(id: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Экран

struct UserProfileView: View {
    let userId: Int

    @StateObject private var model: UserProfileViewModel

    init(userId: Int) {
        self.userId = userId
        _model = StateObject(wrappedValue: UserProfileViewModel(userId: userId))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile = model.profile {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header(for: profile)
                            statistics(for: profile)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                } else if model.isLoading {
                    LoadingView()
                } else if let message = model.errorMessage {
                    ErrorStateView(message: message) {
                        Task { await model.load() }
                    }
                } else {
                    LoadingView()
                }
            }
            .screenBackground()
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
        }
    }

    // MARK: Шапка

    private func header(for profile: Profile) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(urlString: profile.avatar)
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.separator, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if profile.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }

                if let status = profile.status, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                if let registered = registrationText(for: profile) {
                    Text(registered)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func registrationText(for profile: Profile) -> String? {
        guard let timestamp = profile.registerDate, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return "С нами с \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: Статистика

    private var statColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private func statistics(for profile: Profile) -> some View {
        let counts: ProfileExtraCounts = profile
        return LazyVGrid(columns: statColumns, spacing: 10) {
            UserProfileStat(value: profile.watchingCount, title: "Смотрю")
            UserProfileStat(value: profile.planCount, title: "В планах")
            UserProfileStat(value: profile.completedCount, title: "Просмотрено")
            UserProfileStat(value: profile.holdOnCount, title: "Отложено")
            UserProfileStat(value: profile.droppedCount, title: "Брошено")
            UserProfileStat(value: profile.favoriteCount, title: "Любимых")
            UserProfileStat(value: profile.watchedEpisodeCount, title: "Серий")
            UserProfileStat(value: counts.commentCount, title: "Комментариев")
            UserProfileStat(value: counts.collectionCount, title: "Коллекций")
        }
    }
}

// MARK: - Счётчики, которых пока нет в модели

/// Сервер отдаёт в профиле `comment_count` и `collection_count`, а сетка экрана должна
/// показывать оба счётчика. В текущей модели `Profile` (Models.swift) этих полей ещё нет,
/// поэтому требования протокола закрыты реализацией по умолчанию: сейчас это `nil`
/// (в интерфейсе — ноль). Как только поля появятся в модели, их значения подхватятся
/// через свидетельство протокола автоматически, без правки этого экрана.
private protocol ProfileExtraCounts {
    var commentCount: Int? { get }
    var collectionCount: Int? { get }
}

private extension ProfileExtraCounts {
    var commentCount: Int? { nil }
    var collectionCount: Int? { nil }
}

extension Profile: ProfileExtraCounts {}

// MARK: - Плитка статистики

private struct UserProfileStat: View {
    let value: Int?
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value ?? 0)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .cardSurface()
    }
}
