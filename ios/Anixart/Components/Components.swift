import SwiftUI
import UIKit

// MARK: - Картинка с сервера

/// Картинка с сервера через общий `ImageCache`.
///
/// Раньше здесь был `AsyncImage`, у которого нет общего кэша: каждая ячейка
/// списка начинала загрузку заново. Теперь данные берутся из
/// `ImageCache.shared` (память → диск → сеть), а неактивные загрузки
/// отменяются вместе с `.task`.
struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fill

    /// Явный `init` нужен, потому что `private @State` сделал бы
    /// синтезированный memberwise-init приватным (см. Access Control).
    init(urlString: String?, contentMode: ContentMode = .fill) {
        self.urlString = urlString
        self.contentMode = contentMode
    }

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        // При смене URL SwiftUI отменяет старую задачу и запускает новую.
        .task(id: urlString) {
            await loadImage()
        }
    }

    private var imageURL: URL? {
        guard let raw = urlString, !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url
    }

    private var placeholder: some View {
        ZStack {
            Theme.surfaceHigh
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    @MainActor
    private func loadImage() async {
        // При смене URL старая картинка не должна мелькать под новой.
        uiImage = nil
        guard let url = imageURL else { return }

        guard let data = await ImageCache.shared.imageData(for: url),
              !Task.isCancelled,
              let image = UIImage(data: data) else {
            return          // плейсхолдер остаётся при ошибке/отмене
        }
        uiImage = image
    }
}

// MARK: - Постер

struct ReleasePoster: View {
    let release: Release
    var width: CGFloat? = nil
    var height: CGFloat = 190

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: release.image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            if let grade = release.grade, grade > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                    Text(release.gradeText)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(7)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }
}

// MARK: - Карточка релиза

struct ReleaseCard: View {
    let release: Release
    var posterWidth: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReleasePoster(release: release, width: posterWidth, height: posterWidth * 1.45)

            Text(release.displayTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: posterWidth, alignment: .leading)

            if !release.subtitle.isEmpty {
                Text(release.subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }
        }
    }
}

// MARK: - Полка

struct ShelfView: View {
    let title: String
    let releases: [Release]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(releases) { release in
                        NavigationLink {
                            ReleaseView(releaseId: release.id)
                        } label: {
                            ReleaseCard(release: release)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Чипы

struct ChipView: View {
    let text: String
    var selected: Bool = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(selected ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Theme.accent : Theme.surfaceHigh, in: Capsule())
    }
}

// MARK: - Служебные состояния

struct LoadingView: View {
    var body: some View {
        ProgressView()
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 32)
            Button("Повторить", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
