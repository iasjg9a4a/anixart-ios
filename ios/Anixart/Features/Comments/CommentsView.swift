import Foundation
import SwiftUI

// MARK: - Модель экрана

@MainActor
final class CommentsViewModel: ObservableObject {
    let releaseId: Int

    @Published private(set) var comments: [ReleaseComment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPage: Int = 0
    @Published private(set) var totalPages: Int = 0

    private let api = APIClient.shared

    init(releaseId: Int) {
        self.releaseId = releaseId
    }

    /// Есть ли следующая страница.
    var canLoadMore: Bool { currentPage < totalPages }

    func loadFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await api.releaseComments(releaseId: releaseId, page: 1)
            comments = page.content
            currentPage = page.currentPage ?? 1
            totalPages = page.totalPageCount ?? 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }

        let nextPage = currentPage + 1
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await api.releaseComments(releaseId: releaseId, page: nextPage)
            let loadedIds = Set(comments.map { $0.id })
            comments += page.content.filter { !loadedIds.contains($0.id) }
            currentPage = page.currentPage ?? nextPage
            totalPages = page.totalPageCount ?? totalPages
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Экран комментариев

struct CommentsView: View {
    let releaseId: Int

    @StateObject private var model: CommentsViewModel

    init(releaseId: Int) {
        self.releaseId = releaseId
        _model = StateObject(wrappedValue: CommentsViewModel(releaseId: releaseId))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .screenBackground()
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadFirstPage() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.comments.isEmpty {
            LazyVStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonReleaseRow()
                }
            }
        } else if let message = model.errorMessage, model.comments.isEmpty {
            ErrorStateView(message: message) {
                Task { await model.loadFirstPage() }
            }
            .frame(height: 360)
        } else if visibleComments.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 12) {
                ForEach(visibleComments) { comment in
                    CommentCardView(comment: comment)
                }

                if model.canLoadMore {
                    loadMoreButton
                }
            }
        }
    }

    /// Удалённые комментарии сервер тоже присылает — их не показываем.
    private var visibleComments: [ReleaseComment] {
        model.comments.filter { $0.isVisible }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)

            Text("Комментариев пока нет")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
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
}

// MARK: - Карточка комментария

private struct CommentCardView: View {
    let comment: ReleaseComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(urlString: comment.profile?.avatar, contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.separator, lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(comment.profile?.displayName ?? "Пользователь")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if comment.profile?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }

                    Spacer(minLength: 4)

                    Text(dateText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                if let message = comment.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasFooter {
                    HStack(spacing: 10) {
                        if let likes = likesCount {
                            HStack(spacing: 4) {
                                Image(systemName: "heart")
                                    .font(.caption2)
                                Text("\(likes)")
                                    .font(.caption2.monospacedDigit())
                            }
                            .foregroundStyle(Theme.textTertiary)
                        }

                        if comment.isSpoiler == true {
                            badge("спойлер", color: Theme.accent)
                        }

                        if comment.isEdited == true {
                            badge("изменён", color: Theme.textTertiary)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var hasFooter: Bool {
        likesCount != nil || comment.isSpoiler == true || comment.isEdited == true
    }

    private var likesCount: Int? {
        guard let likes = comment.voteCount ?? comment.likesCount, likes > 0 else { return nil }
        return likes
    }

    private var dateText: String {
        guard let timestamp = comment.timestamp else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .omitted)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}
