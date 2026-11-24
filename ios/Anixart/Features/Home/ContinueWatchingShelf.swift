import Foundation
import SwiftUI

// MARK: - Карточка полки

/// Один пункт «Продолжить просмотр»: релиз и серия, на которой остановился просмотр.
///
/// `PlaybackProgress` хранит только ключ `releaseId-sourceId-position` и пройденные
/// секунды, поэтому релиз догружается с сервера, а `seconds` нужны для подписи
/// и полоски прогресса.
struct ContinueItem: Identifiable {
    let release: Release
    let seconds: Int
    let position: Int
    let sourceId: Int

    var id: Int { release.id }

    /// Условная длительность серии в минутах, если сервер не отдал длительность релиза.
    private static let nominalEpisodeMinutes = 24

    /// Позиция в формате `MM:SS` для подписи карточки.
    var timeLabel: String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Доля пройденной серии для полоски: 0...1.
    ///
    /// `PlaybackProgress` не помнит длительность серии, поэтому считаем от `Release.duration`
    /// (минуты). Если сервер его не прислал — от условных 24 минут: полоска остаётся
    /// осмысленной, но приблизительной.
    var progress: Double {
        let minutes = release.duration ?? 0
        let totalSeconds = minutes > 0 ? minutes * 60 : Self.nominalEpisodeMinutes * 60
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(seconds) / Double(totalSeconds)))
    }
}

// MARK: - Модель полки

/// Загружает карточки «Продолжить просмотр» для главной.
///
/// Позиции уже лежат локально (`PlaybackProgress.continueWatching()`), но карточке нужны
/// постер и название, поэтому релизы догружаются с сервера параллельно. Полка
/// необязательная: ошибки отдельных запросов пропускаются, а если не загрузилось ничего,
/// блок просто не показывается (см. `ContinueWatchingShelf`).
@MainActor
final class ContinueWatchingViewModel: ObservableObject {
    @Published private(set) var items: [ContinueItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// `continueWatching()` уже отдаёт до десяти записей — больше не запрашиваем.
    private let limit = 10

    func load() async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let entries = PlaybackProgress.shared.continueWatching()
        guard !entries.isEmpty else {
            items = []
            return
        }

        let keys: [(key: PlaybackKey, seconds: Int)] = entries.prefix(limit).compactMap { entry in
            guard let key = PlaybackKey(storageKey: entry.key) else { return nil }
            return (key: key, seconds: entry.seconds)
        }
        guard !keys.isEmpty else {
            items = []
            return
        }

        let releases = await Self.loadReleases(ids: keys.map { $0.key.releaseId })
        var loadedItems: [ContinueItem] = []
        var seenReleases = Set<Int>()

        for (entry, release) in zip(keys, releases) {
            guard let release else { continue }
            // Одна карточка на релиз, даже если сохранено несколько его серий:
            // `continueWatching()` уже отсортирован от новых к старым, поэтому
            // остаётся самая свежая серия.
            guard seenReleases.insert(release.id).inserted else { continue }
            loadedItems.append(ContinueItem(release: release,
                                            seconds: entry.seconds,
                                            position: entry.key.position,
                                            sourceId: entry.key.sourceId))
        }

        items = loadedItems
        if loadedItems.isEmpty {
            errorMessage = "Не удалось загрузить релизы для «Продолжить просмотр»"
        }
    }

    /// Параллельно загружает релизы и сохраняет порядок ключей: первым идёт то,
    /// что смотрели последним. `nil` — запрос не удался, такую карточку пропускаем.
    private static func loadReleases(ids: [Int]) async -> [Release?] {
        await withTaskGroup(of: (Int, Release?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    (index, try? await APIClient.shared.release(id: id))
                }
            }

            var releases = [Release?](repeating: nil, count: ids.count)
            for await (index, release) in group {
                releases[index] = release
            }
            return releases
        }
    }
}

// MARK: - Полка

/// Горизонтальная полка «Продолжить просмотр» на главной.
///
/// Пока серий в истории нет — `EmptyView`, чтобы главная выглядела как раньше.
/// Карточка открывает `ReleaseView`; плеер сам перемотает серию на сохранённую
/// секунду через `PlaybackProgress`.
struct ContinueWatchingShelf: View {
    @StateObject private var model = ContinueWatchingViewModel()

    var body: some View {
        Group {
            if model.items.isEmpty {
                EmptyView()
            } else {
                content
            }
        }
        .task { await model.load() }
    }

    // MARK: - Контент

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Продолжить просмотр")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(model.items) { item in
                        NavigationLink {
                            ReleaseView(releaseId: item.release.id)
                        } label: {
                            ContinueWatchingCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Карточка

/// Карточка продолжения: постер 128×186, название, серия с позицией и полоска прогресса.
private struct ContinueWatchingCard: View {
    let item: ContinueItem

    private let posterWidth: CGFloat = 128
    private let posterHeight: CGFloat = 186
    private let progressHeight: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster

            Text(item.release.displayTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: posterWidth, alignment: .leading)

            Text("Серия \(item.position) · \(item.timeLabel)")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: posterWidth, alignment: .leading)
        }
    }

    /// Постер с полоской прогресса по нижнему краю — как у плеера.
    private var poster: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(urlString: item.release.image)
                .frame(width: posterWidth, height: posterHeight)
                .clipped()

            progressBar
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    /// Две полосы вместо `ProgressView`: ширина карточки фиксирована, доля известна.
    private var progressBar: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.55))

            Rectangle()
                .fill(Theme.accent)
                .frame(width: posterWidth * CGFloat(item.progress))
        }
        .frame(height: progressHeight)
    }
}
