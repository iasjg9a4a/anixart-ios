import SwiftUI

// MARK: - Легальные площадки релиза
//
// Отдельный запрос `release/streaming/platform/{releaseId}` отдаёт официальные
// площадки (Netflix, Кинопоиск и т.п.). Секция необязательная: пока данных нет
// и при ошибке — `EmptyView` (страница релиза выглядит как раньше), пустой
// ответ сервера — тоже `EmptyView`. Карточки — иконка 44 × 44 и название;
// если у площадки есть ссылка, вся карточка — `Link`, который открывает её
// системным браузером.

// MARK: - Модель

/// Загружает площадки релиза. Ошибки намеренно игнорируются: блок
/// «Смотреть легально» необязательный и не должен показывать ошибку на карточке.
@MainActor
final class ReleaseStreamingSourcesViewModel: ObservableObject {
    @Published private(set) var platforms: [StreamingPlatform] = []
    @Published private(set) var isLoading = false

    /// Для какого релиза площадки уже загружены: повторное появление секции
    /// (и повторный `.task`) не дёргает сеть заново.
    private var loadedReleaseId: Int?

    func load(releaseId: Int) async {
        guard !isLoading else { return }
        guard loadedReleaseId != releaseId else { return }

        isLoading = true
        // При смене релиза старые площадки не должны мелькать под новыми.
        platforms = []
        defer { isLoading = false }

        do {
            platforms = try await APIClient.shared.releaseStreamingPlatforms(releaseId: releaseId)
            loadedReleaseId = releaseId
        } catch {
            // Тихо: пустой список = секция скрыта.
            platforms = []
        }
    }
}

// MARK: - Секция

/// Блок «Смотреть легально» на странице релиза.
///
/// Нет площадок — секция не показывается вовсе (`EmptyView`): заголовок без
/// содержимого на карточке релиза не нужен.
struct ReleaseStreamingSourcesSection: View {
    let releaseId: Int

    @StateObject private var model = ReleaseStreamingSourcesViewModel()

    // Приватный @StateObject делает синтезированный memberwise-init приватным,
    // поэтому даём явный публичный инициализатор для вызова из других файлов.
    init(releaseId: Int) {
        self.releaseId = releaseId
    }

    var body: some View {
        Group {
            if !model.platforms.isEmpty {
                content
            } else {
                EmptyView()
            }
        }
        .task { await model.load(releaseId: releaseId) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Смотреть легально")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, StreamingSectionMetrics.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: StreamingSectionMetrics.cardSpacing) {
                    ForEach(model.platforms) { platform in
                        ReleaseStreamingPlatformCard(platform: platform)
                    }
                }
                .padding(.horizontal, StreamingSectionMetrics.horizontalPadding)
            }
        }
        .padding(.bottom, StreamingSectionMetrics.bottomPadding)
    }
}

// MARK: - Карточка площадки

/// Иконка платформы и её название; при наличии ссылки карточка — `Link`
/// (открывает URL системным браузером, как настройки приложения).
private struct ReleaseStreamingPlatformCard: View {
    let platform: StreamingPlatform

    var body: some View {
        Group {
            if let url = platform.linkURL {
                Link(destination: url) {
                    card(isLink: true)
                }
                .buttonStyle(.plain)
            } else {
                card(isLink: false)
            }
        }
    }

    private func card(isLink: Bool) -> some View {
        HStack(spacing: 10) {
            RemoteImage(urlString: platform.icon)
                .frame(
                    width: StreamingSectionMetrics.iconSize,
                    height: StreamingSectionMetrics.iconSize
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: StreamingSectionMetrics.iconRadius,
                        style: .continuous
                    )
                )
                // Тёмные логотипы (у Netflix фон чёрный) иначе сливаются с карточкой.
                .overlay(
                    RoundedRectangle(
                        cornerRadius: StreamingSectionMetrics.iconRadius,
                        style: .continuous
                    )
                    .stroke(Theme.separator, lineWidth: 1)
                )

            Text(platform.displayName)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            if isLink {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .cardSurface()
    }
}

// MARK: - Геометрия

private enum StreamingSectionMetrics {
    static let horizontalPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 22
    static let cardSpacing: CGFloat = 10
    static let iconSize: CGFloat = 44
    static let iconRadius: CGFloat = 10
}
