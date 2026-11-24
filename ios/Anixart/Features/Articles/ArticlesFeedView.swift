import SwiftUI

// MARK: - Модель ленты статей

/// Лента статей: `search/feed/{page}` отдаёт страницу `Paged<Article>`.
/// Размер страницы сервер не сообщает, поэтому границу пагинации считаем
/// по `total_count`; страницы в клиенте 1-based (`Paged` уже прибавил единицу).
@MainActor
final class ArticlesFeedViewModel: ObservableObject {
    @Published private(set) var articles: [Article] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPage = 0
    @Published private(set) var totalPages = 0

    private let api = APIClient.shared
    /// Размер страницы, который реально отдал сервер (обычно 25 статей).
    private var pageSize = 0

    var canLoadMore: Bool { currentPage > 0 && currentPage < totalPages }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await api.articles(page: 1)
            articles = page.content
            currentPage = 1
            pageSize = page.content.count
            totalPages = resolveTotalPages(page, loadedPage: 1)
        } catch {
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
            let page = try await api.articles(page: nextPage)
            let loadedIds = Set(articles.map { $0.id })
            let fresh = page.content.filter { !loadedIds.contains($0.id) }
            articles.append(contentsOf: fresh)
            currentPage = nextPage

            // Пустая или целиком повторяющаяся страница — дальше двигаться некуда.
            totalPages = fresh.isEmpty ? nextPage : resolveTotalPages(page, loadedPage: nextPage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `total_page_count` сервер присылает не всегда, поэтому основной расчёт —
    /// по `total_count` и размеру страницы. Без метаданных полную страницу
    /// считаем поводом показать «Показать ещё»: пустая страница кнопку уберёт.
    private func resolveTotalPages(_ page: Paged<Article>, loadedPage: Int) -> Int {
        if let totalCount = page.totalCount, totalCount > 0, pageSize > 0 {
            let pages = (totalCount + pageSize - 1) / pageSize
            return max(pages, loadedPage)
        }
        if let totalPages = page.totalPageCount, totalPages > 0 {
            return max(totalPages, loadedPage)
        }
        return page.content.count >= pageSize && pageSize > 0 ? loadedPage + 1 : loadedPage
    }
}

// MARK: - Экран ленты статей

struct ArticlesFeedView: View {
    @StateObject private var model = ArticlesFeedViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .screenBackground()
            .navigationTitle("Статьи")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await model.load() }
            .task { await model.load() }
        }
    }

    // MARK: - Контент

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.articles.isEmpty {
            LazyVStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in
                    ArticleSkeletonRow()
                }
            }
        } else if let message = model.errorMessage, model.articles.isEmpty {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        } else if model.articles.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 12) {
                ForEach(model.articles) { article in
                    NavigationLink {
                        ArticleDetailView(articleId: article.id)
                    } label: {
                        ArticleFeedCard(article: article)
                    }
                    .buttonStyle(.plain)
                }

                if let message = model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                if model.canLoadMore {
                    loadMoreButton
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("Статей пока нет")
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

// MARK: - Карточка статьи

private struct ArticleFeedCard: View {
    let article: Article

    private let coverHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover

            VStack(alignment: .leading, spacing: 7) {
                Text(articleDisplayTitle(article))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let description = article.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                footer
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .cardSurface()
    }

    /// Обложка — первая картинка из `media`, иначе плейсхолдер с инициалами.
    @ViewBuilder
    private var cover: some View {
        if article.imageURL != nil {
            RemoteImage(urlString: article.image, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .frame(height: coverHeight)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Theme.accentSoft, Theme.surfaceHigh],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Text(initials)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
            .frame(height: coverHeight)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            channelLabel

            Spacer(minLength: 4)

            if !dateText.isEmpty {
                Text(dateText)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 3) {
                Image(systemName: "bubble.right")
                    .font(.caption2)
                Text("\(article.commentCount ?? 0)")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var channelLabel: some View {
        if let channel = article.channel {
            HStack(spacing: 5) {
                RemoteImage(urlString: channel.avatar, contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())

                Text(channel.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        } else if let author = article.author {
            Text(author.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var initials: String {
        let letters = articleDisplayTitle(article)
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        return letters.isEmpty ? "С" : String(letters).uppercased()
    }

    private var dateText: String { articleDateText(article.creationDate) }
}

// MARK: - Скелетон карточки статьи

/// Плейсхолдер первой загрузки ленты: обложка и три строки текста —
/// геометрия настоящей `ArticleFeedCard`, но без данных.
private struct ArticleSkeletonRow: View {
    private let coverHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock(height: coverHeight, cornerRadius: Theme.cardRadius)

            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: proxy.size.width * 0.92, height: 14, cornerRadius: 4)
                    SkeletonBlock(width: proxy.size.width * 0.70, height: 11, cornerRadius: 4)
                    SkeletonBlock(width: proxy.size.width * 0.34, height: 11, cornerRadius: 4)
                }
            }
            .frame(height: 52)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .cardSurface()
    }
}

// MARK: - Модель статьи

@MainActor
final class ArticleDetailViewModel: ObservableObject {
    let articleId: Int

    @Published private(set) var article: Article?
    @Published private(set) var comments: [ReleaseComment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = APIClient.shared

    init(articleId: Int) {
        self.articleId = articleId
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Комментарии — необязательная часть экрана: если их страница
            // не пришла, статья всё равно должна открыться.
            async let articleTask = api.article(id: articleId)
            async let commentsTask = api.articleComments(articleId: articleId, page: 1)

            let commentsPage = try? await commentsTask
            let loadedArticle = try await articleTask

            article = loadedArticle
            comments = commentsPage?.content.filter { $0.isVisible } ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Экран статьи

struct ArticleDetailView: View {
    let articleId: Int

    @StateObject private var model: ArticleDetailViewModel

    init(articleId: Int) {
        self.articleId = articleId
        _model = StateObject(wrappedValue: ArticleDetailViewModel(articleId: articleId))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .screenBackground()
        .navigationTitle("Статья")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if let article = model.article {
            articleContent(article)
        } else if model.isLoading {
            LoadingView()
                .frame(height: 400)
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        } else {
            Text("Статья недоступна")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func articleContent(_ article: Article) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            articleHeader(article)

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            articleBody(article)

            commentsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(articleDisplayTitle(article))
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(articleMetaLine(article))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    /// Текст статьи лежит в `payload.blocks`; если блоков нет, показываем
    /// описание из модели.
    @ViewBuilder
    private func articleBody(_ article: Article) -> some View {
        if article.blocks.isEmpty {
            Text(article.description ?? "Текста у статьи нет")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ArticleBlocksView(blocks: article.blocks)
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Комментарии")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)

            if model.comments.isEmpty {
                Text("Комментариев пока нет")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(model.comments) { comment in
                    ArticleCommentCard(comment: comment)
                }
            }
        }
    }
}

// MARK: - Блоки статьи

/// Редактор присылает блоки paragraph/header/quote/media/list/delimiter.
/// Неизвестный блок показываем как абзац, только если у него есть текст.
private struct ArticleBlocksView: View {
    let blocks: [ArticleBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ArticleBlock) -> some View {
        switch block.type ?? block.name ?? "" {
        case "header":
            if let text = plainText(block.data?.text) {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "quote":
            if let text = plainText(block.data?.text) {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)

                    Text(text)
                        .font(.body.italic())
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case "media":
            if let urlString = mediaURLString(block) {
                VStack(alignment: .leading, spacing: 6) {
                    RemoteImage(urlString: urlString, contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

                    if let caption = plainText(block.data?.caption) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        case "delimiter":
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
        default:
            if let text = plainText(block.data?.text) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Текст блоков приходит HTML-фрагментом — чистим общим разбором `ArticleText`.
    private func plainText(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let text = ArticleText.normalized(ArticleText.plain(raw))
        return text.isEmpty ? nil : text
    }

    /// Первая валидная картинка из `items` блока `media`.
    private func mediaURLString(_ block: ArticleBlock) -> String? {
        let urls = block.data?.items?.compactMap { $0.url } ?? []
        return urls.first { raw in
            guard !raw.isEmpty, let url = URL(string: raw) else { return false }
            return url.scheme != nil
        }
    }
}

// MARK: - Карточка комментария

private struct ArticleCommentCard: View {
    let comment: ReleaseComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(urlString: comment.profile?.avatar, contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.profile?.displayName ?? "Пользователь")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Text(dateText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)

                    Spacer(minLength: 0)
                }

                if let message = comment.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var dateText: String {
        guard let timestamp = comment.timestamp else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Общие помощники

/// У модели статьи нет поля `title`: заголовок вычисляется из `payload.blocks`,
/// а если блоков нет — модель отдаёт «Без названия». Такую запись подписываем
/// как «Статья канала».
private func articleDisplayTitle(_ article: Article) -> String {
    let title = article.title
    if title.isEmpty || title == "Без названия" {
        return "Статья канала"
    }
    return title
}

/// Строка «канал · дата» под заголовком статьи.
private func articleMetaLine(_ article: Article) -> String {
    var parts: [String] = []
    if let channel = article.channel {
        parts.append(channel.displayTitle)
    } else if let author = article.author {
        parts.append(author.displayName)
    }
    let date = articleDateText(article.creationDate)
    if !date.isEmpty {
        parts.append(date)
    }
    return parts.joined(separator: " · ")
}

/// Дата статьи: сервер присылает unix-время в секундах.
private func articleDateText(_ timestamp: Int?) -> String {
    guard let timestamp = timestamp else { return "" }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
        .formatted(date: .abbreviated, time: .omitted)
}
