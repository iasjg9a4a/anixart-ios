import SwiftUI

// MARK: - Модель

/// Полка баннеров на главной: `discover/hub` → `interesting`.
///
/// Блок необязательный: если сервер не отдал баннеры или запрос упал,
/// главная должна остаться рабочей, поэтому ошибка только сохраняется
/// в `errorMessage`, а вью её не показывает.
@MainActor
final class BannerShelfViewModel: ObservableObject {
    @Published private(set) var banners: [InterestingItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let discover = try await api.discover()
            // Скрытые сервером баннеры не показываем; на главной хватает первых десяти.
            let visible = (discover.interesting ?? []).filter { $0.isHidden != true }
            banners = Array(visible.prefix(10))
        } catch {
            // Баннеры — необязательный блок: молча оставляем главную без полки.
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Полка

struct BannerShelfView: View {
    @StateObject private var model = BannerShelfViewModel()

    var body: some View {
        Group {
            if model.banners.isEmpty {
                // Нет баннеров (или была ошибка) — не занимаем место на главной.
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(model.banners) { banner in
                            BannerShelfCard(item: banner)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: BannerShelfCard.height)
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Карточка

private struct BannerShelfCard: View {
    /// Ширина баннера на iPhone.
    static let width: CGFloat = 280
    static let height: CGFloat = 158

    let item: InterestingItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: item.image, contentMode: .fill)
                .frame(width: Self.width, height: Self.height)
                .clipped()

            // Затемнение снизу вверх, чтобы текст читался на любом постере.
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0.30), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )

            caption
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(adBadge, alignment: .topTrailing)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// Пометка рекламы: `type == 1` — платный (продвигаемый) баннер.
    @ViewBuilder
    private var adBadge: some View {
        if item.type == 1 {
            Text("Реклама")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(8)
        }
    }
}
