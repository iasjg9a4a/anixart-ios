import SwiftUI

// MARK: - Видео на странице релиза
//
// Отдельный запрос `video/release/{releaseId}` отдаёт видео, сгруппированные по
// категориям (опенинги, трейлеры, клипы). Секция необязательная: пока данных нет —
// скелетон, ошибку не показываем («Видео» просто исчезает), пустой ответ — `EmptyView`.
// Карточки — обложка 16:9 с бейджем хостинга и названием в две строки; нажатие
// отдаётся наружу через `onSelect`, чтобы страница релиза сама решала, чем играть.

// MARK: - Модель

/// Загружает видео релиза и складывает их в блоки-категории.
///
/// Ошибки намеренно игнорируются: блок «Видео» необязательный, и неудачный запрос
/// не должен показывать на карточке релиза ошибку или алерт — секция просто скрывается.
@MainActor
final class ReleaseVideosViewModel: ObservableObject {
    @Published private(set) var blocks: [ReleaseVideoBlock] = []
    @Published private(set) var isLoading = false
    /// Ошибка последнего запроса. Секция её не рисует (видео необязательное) —
    /// поле остаётся для отладки и будущих логов.
    @Published private(set) var errorMessage: String?

    /// Для какого релиза видео уже загружено: повторное появление секции
    /// не дёргает сеть заново.
    private var loadedReleaseId: Int?

    /// Видео, по которым уже летит запрос избранного: второй тап за время
    /// запроса игнорируется, чтобы быстрые нажатия не раздваивали add/delete.
    private var pendingFavorites: Set<Int> = []

    func load(releaseId: Int) async {
        guard !isLoading else { return }
        guard loadedReleaseId != releaseId else { return }

        isLoading = true
        errorMessage = nil
        // При смене релиза старые видео не должны мелькать под новыми.
        blocks = []
        defer { isLoading = false }

        do {
            blocks = try await APIClient.shared.releaseVideos(releaseId: releaseId)
            loadedReleaseId = releaseId
        } catch {
            // Тихо: пустой список = секция скрыта, страница релиза выглядит как раньше.
            blocks = []
            errorMessage = "Не удалось загрузить видео"
        }
    }

    /// Блоки, в которых есть хотя бы одно видео: пустые категории сервер тоже присылает.
    var visibleBlocks: [ReleaseVideoBlock] {
        blocks.filter { !($0.videos ?? []).isEmpty }
    }

    // MARK: - Избранное видео

    /// Переключить избранное видео (`releaseVideoFavorite/add|delete/{r_id}`).
    ///
    /// Карточка меняется сразу, не дожидаясь сети; если запрос не удался, звезда
    /// и счётчик возвращаются к прежнему состоянию. Ошибку не показываем: откат
    /// сам по себе заметен, а секция видео необязательная (см. `load`).
    ///
    /// Гость (нет токена) не получает ни запроса, ни алерта: звезда показывает
    /// серверное `isFavorite`, но тап ничего не делает. Навигации нет.
    func toggleFavorite(videoId: Int) async {
        guard TokenStore.shared.token != nil else { return }
        guard !pendingFavorites.contains(videoId) else { return }
        guard let current = video(withId: videoId) else { return }

        let wasFavorite = current.isFavorite ?? false
        let previousCount = current.favoritesCount
        let target = !wasFavorite

        pendingFavorites.insert(videoId)
        applyFavorite(
            videoId: videoId,
            isFavorite: target,
            favoritesCount: changedCount(previousCount, favorite: target)
        )
        defer { pendingFavorites.remove(videoId) }

        do {
            if target {
                try await APIClient.shared.addReleaseVideoFavorite(videoId: videoId)
            } else {
                try await APIClient.shared.removeReleaseVideoFavorite(videoId: videoId)
            }
        } catch {
            applyFavorite(videoId: videoId, isFavorite: wasFavorite, favoritesCount: previousCount)
        }
    }

    /// Видео по id во всех блоках: сервер держит одно видео только в одной категории.
    private func video(withId id: Int) -> ReleaseVideo? {
        for block in blocks {
            if let found = (block.videos ?? []).first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    /// Счётчик избранного после переключения: ±1, но не ниже нуля.
    /// Если сервер счётчик не прислал (`nil`), его и не выдумываем.
    private func changedCount(_ count: Int?, favorite: Bool) -> Int? {
        guard let count = count else { return nil }
        return max(count + (favorite ? 1 : -1), 0)
    }

    /// Обновить `isFavorite`/`favoritesCount` видео прямо в блоках.
    private func applyFavorite(videoId: Int, isFavorite: Bool, favoritesCount: Int?) {
        for blockIndex in blocks.indices {
            guard var videos = blocks[blockIndex].videos,
                  let videoIndex = videos.firstIndex(where: { $0.id == videoId }) else { continue }
            videos[videoIndex].isFavorite = isFavorite
            videos[videoIndex].favoritesCount = favoritesCount
            blocks[blockIndex].videos = videos
            return
        }
    }
}

// MARK: - Секция

/// Блок «Видео» на странице релиза: заголовок, категории и горизонтальные полки карточек.
///
/// Вызывающий сам решает, что делать с выбранным видео (запуск плеера, переход),
/// поэтому секция не знает про `PlaybackTarget`.
struct ReleaseVideosSection: View {
    let releaseId: Int
    let onSelect: (ReleaseVideo) -> Void

    @StateObject private var model = ReleaseVideosViewModel()

    /// Явный `init`: замыкание хранится в свойстве, а значит должно быть `@escaping`.
    init(releaseId: Int, onSelect: @escaping (ReleaseVideo) -> Void) {
        self.releaseId = releaseId
        self.onSelect = onSelect
    }

    var body: some View {
        Group {
            if !model.visibleBlocks.isEmpty {
                content
            } else if model.isLoading {
                skeleton
            } else {
                EmptyView()
            }
        }
        .task { await model.load(releaseId: releaseId) }
    }

    // MARK: - Контент

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Видео")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, VideoSectionMetrics.horizontalPadding)

            ForEach(model.visibleBlocks.indices, id: \.self) { index in
                category(model.visibleBlocks[index])
            }
        }
        .padding(.bottom, VideoSectionMetrics.bottomPadding)
    }

    /// Одна категория: подпись (если сервер её дал) и полка карточек.
    private func category(_ block: ReleaseVideoBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = block.category?.name, !title.isEmpty {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, VideoSectionMetrics.horizontalPadding)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: VideoSectionMetrics.cardSpacing) {
                    ForEach(block.videos ?? []) { video in
                        ReleaseVideoCard(
                            video: video,
                            onSelect: onSelect,
                            onToggleFavorite: { toggleFavorite(video.id) }
                        )
                    }
                }
                .padding(.horizontal, VideoSectionMetrics.horizontalPadding)
            }
        }
    }

    /// Тап по звезде: гость отсекается во вью-модели, повторный тап во время
    /// запроса — тоже (см. `toggleFavorite(videoId:)`).
    private func toggleFavorite(_ videoId: Int) {
        Task { await model.toggleFavorite(videoId: videoId) }
    }

    // MARK: - Скелетон загрузки

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBlock(width: 92, height: 17, cornerRadius: 5)
                .padding(.horizontal, VideoSectionMetrics.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: VideoSectionMetrics.cardSpacing) {
                    ForEach(0..<3, id: \.self) { _ in
                        ReleaseVideoCardSkeleton()
                    }
                }
                .padding(.horizontal, VideoSectionMetrics.horizontalPadding)
            }
        }
        .padding(.bottom, VideoSectionMetrics.bottomPadding)
    }
}

// MARK: - Карточка видео

/// Обложка 200 × 112 с бейджем хостинга и названием под ней в две строки.
/// В правом верхнем углу обложки — звезда избранного (tap не открывает плеер).
private struct ReleaseVideoCard: View {
    let video: ReleaseVideo
    let onSelect: (ReleaseVideo) -> Void
    let onToggleFavorite: () -> Void

    init(video: ReleaseVideo,
         onSelect: @escaping (ReleaseVideo) -> Void,
         onToggleFavorite: @escaping () -> Void) {
        self.video = video
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
    }

    var body: some View {
        Button {
            onSelect(video)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover

                Text(video.displayTitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(
                        width: VideoSectionMetrics.coverWidth,
                        height: VideoSectionMetrics.titleHeight,
                        alignment: .topLeading
                    )
            }
            .frame(width: VideoSectionMetrics.coverWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        // Overlay, а не вложенная кнопка: тап по звезде не открывает плеер.
        .overlay(favoriteButton.padding(6), alignment: .topTrailing)
    }

    /// Звезда избранного поверх обложки: заливка — по серверному `isFavorite`.
    ///
    /// Гость её тоже видит, но тап ничего не делает (проверка токена во вью-модели).
    private var favoriteButton: some View {
        Button {
            onToggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFavorite ? Theme.accent : Color.white)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Убрать видео из избранного" : "Добавить видео в избранное")
    }

    private var isFavorite: Bool { video.isFavorite ?? false }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: video.image, contentMode: .fill)
                .frame(
                    width: VideoSectionMetrics.coverWidth,
                    height: VideoSectionMetrics.coverHeight
                )
                .clipped()

            hostingBadge
                .padding(6)
        }
        .frame(
            width: VideoSectionMetrics.coverWidth,
            height: VideoSectionMetrics.coverHeight,
            alignment: .bottomLeading
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    /// Маленький бейдж хостинга поверх обложки: символ + короткое название.
    private var hostingBadge: some View {
        let badge = video.hostingKind.badge
        return HStack(spacing: 4) {
            Image(systemName: badge.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(badge.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6), in: Capsule())
    }
}

// MARK: - Скелетон карточки

/// Заглушка карточки: обложка 16:9 и две строки подписи.
private struct ReleaseVideoCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(
                width: VideoSectionMetrics.coverWidth,
                height: VideoSectionMetrics.coverHeight,
                cornerRadius: Theme.cardRadius
            )
            SkeletonBlock(
                width: VideoSectionMetrics.coverWidth * 0.84,
                height: 10,
                cornerRadius: 4
            )
            SkeletonBlock(
                width: VideoSectionMetrics.coverWidth * 0.56,
                height: 10,
                cornerRadius: 4
            )
        }
        .frame(width: VideoSectionMetrics.coverWidth, alignment: .leading)
    }
}

// MARK: - Геометрия и бейдж

private enum VideoSectionMetrics {
    static let horizontalPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 22
    static let coverWidth: CGFloat = 200
    static let coverHeight: CGFloat = 112
    static let titleHeight: CGFloat = 34
    static let cardSpacing: CGFloat = 12
}

private extension ReleaseVideoHosting {
    /// SF-символ и подпись бейджа хостинга на обложке.
    var badge: (symbol: String, title: String) {
        switch self {
        case .youtube:
            return ("play.rectangle", "YouTube")
        case .vk:
            return ("video", "VK")
        case .rutube:
            return ("play.tv", "RuTube")
        case .sibnet:
            return ("play.rectangle", "Sibnet")
        case .other:
            return ("play.rectangle", "Видео")
        }
    }
}
