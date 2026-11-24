import SwiftUI

// MARK: - Скелетоны загрузки
//
// Плейсхолдеры для состояний «данные ещё грузятся»: те же размеры, что у
// настоящих карточек, но с бегущим градиентным бликом. Экраны подключают их
// вместо `LoadingView()`, пока списка нет:
//
//   ScrollView { SkeletonGrid().padding(.horizontal, 16) }      // каталог/поиск
//   SkeletonShelf()                                             // полка на главной
//   ForEach(0..<6, id: \.self) { _ in SkeletonReleaseRow() }    // история/комментарии
//
// Анимация живёт только пока блок на экране: старт в `onAppear`, остановка
// в `onDisappear` — скрытые скелетоны CPU не крутят.

// MARK: - Базовый блок

/// Серый скруглённый прямоугольник `Theme.surfaceHigh` с анимацией «шиммера».
///
/// Если `width` не задан — блок растягивается по ширине предложенного места
/// (удобно для строк текста), иначе занимает ровно `width` × `height`.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    /// -1 — блик слева за пределами блока, +1 — справа за пределами.
    @State private var phase: CGFloat = -1
    @State private var isAnimating = false

    private var shimmerAnimation: Animation {
        .linear(duration: 1.2).repeatForever(autoreverses: false)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.surfaceHigh)
            .frame(width: width, height: height)
            .overlay(shimmer)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear { startShimmer() }
            .onDisappear { stopShimmer() }
    }

    /// Бегущий блик: полоса подсветки, размытая по краям градиентной маской,
    /// проезжает слева направо. Ширина/высота берутся у самого блока.
    private var shimmer: some View {
        GeometryReader { proxy in
            let stripWidth = proxy.size.width * 0.7

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: stripWidth)
                .mask(
                    LinearGradient(
                        colors: [.clear, Color.white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .offset(x: phase * (proxy.size.width + stripWidth))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func startShimmer() {
        guard !isAnimating else { return }
        isAnimating = true
        phase = -1
        withAnimation(shimmerAnimation) {
            phase = 1
        }
    }

    private func stopShimmer() {
        isAnimating = false
        withAnimation(nil) {
            phase = -1
        }
    }
}

// MARK: - Карточка постера

/// Карточка полки: постер 128 × 186 и две строки подписи.
struct SkeletonPosterCard: View {
    var posterWidth: CGFloat = 128
    var posterHeight: CGFloat = 186

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(
                width: posterWidth,
                height: posterHeight,
                cornerRadius: Theme.cardRadius
            )

            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: posterWidth * 0.86, height: 10, cornerRadius: 4)
                SkeletonBlock(width: posterWidth * 0.55, height: 9, cornerRadius: 4)
            }
        }
        .frame(width: posterWidth, alignment: .leading)
    }
}

// MARK: - Строка списка

/// Горизонтальная строка: постер 52 × 74 и три строки текста
/// (история просмотров, комментарии, компактные списки).
/// Внешние отступы не задаёт — как и настоящая строка, вписывается в контейнер.
struct SkeletonReleaseRow: View {
    var posterWidth: CGFloat = 52
    var posterHeight: CGFloat = 74

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBlock(
                width: posterWidth,
                height: posterHeight,
                cornerRadius: Theme.cardRadius
            )

            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: proxy.size.width * 0.94, height: 12, cornerRadius: 4)
                    SkeletonBlock(width: proxy.size.width * 0.62, height: 10, cornerRadius: 4)
                    SkeletonBlock(width: proxy.size.width * 0.40, height: 10, cornerRadius: 4)
                }
            }
            .frame(height: posterHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Сетка

/// Скелетон каталога/поиска: LazyVGrid из `items` карточек постера.
/// Внешние отступы оставлены вызывающему — как у настоящего `LazyVGrid`.
struct SkeletonGrid: View {
    var items: Int = 6
    var columnCount: Int = 2

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14),
            count: max(columnCount, 1)
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(0..<items, id: \.self) { _ in
                SkeletonPosterCard()
            }
        }
    }
}

// MARK: - Полка

/// Скелетон полки: заглушка заголовка и горизонтальный ряд из `items` карточек.
/// Повторяет геометрию `ShelfView`: заголовок и контент с отступом 16.
struct SkeletonShelf: View {
    var items: Int = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(width: 140, height: 16, cornerRadius: 5)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<items, id: \.self) { _ in
                        SkeletonPosterCard()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
