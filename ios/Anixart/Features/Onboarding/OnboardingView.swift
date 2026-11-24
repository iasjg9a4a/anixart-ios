import SwiftUI

// MARK: - Модель страницы

/// Одна страница приветственного экрана.
/// Записи в UserDefaults здесь нет: страница только описывает контент.
struct OnboardingPage: Identifiable {
    let id: Int
    let systemImage: String
    let title: String
    let subtitle: String
}

extension OnboardingPage {
    /// Три страницы знакомства с клиентом. SF Symbols входят в iOS 16.
    static let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            systemImage: "magnifyingglass",
            title: "Каталог и поиск",
            subtitle: "Тысячи релизов с фильтрами по жанрам, году и рейтингу. Найди нужное за пару секунд."
        ),
        OnboardingPage(
            id: 1,
            systemImage: "play.rectangle.fill",
            title: "Просмотр серий",
            subtitle: "Плеер запоминает, где ты остановился, и продолжает с того же места на любом устройстве."
        ),
        OnboardingPage(
            id: 2,
            systemImage: "square.grid.2x2.fill",
            title: "Коллекции и история",
            subtitle: "Собирай релизы в списки, отмечай просмотренное и возвращайся к нему когда угодно."
        )
    ]
}

// MARK: - Экран

/// Приветственный экран при первом запуске.
/// Никакого состояния наружу не пишет: решение «показывать ещё раз или нет»
/// принимает вызывающий код в замыкании `onFinish`.
struct OnboardingView: View {
    @State private var page = 0

    /// Вызывается по кнопке «Начать» на последней странице.
    var onFinish: () -> Void

    /// Явный init: синтезированный memberwise-инициализатор в структуре
    /// с закрытыми (@State private) полями вызывающему коду не гарантирован.
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    private static let lastPage = OnboardingPage.pages.count - 1

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(OnboardingPage.pages) { item in
                    pageContent(item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            continueButton
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .screenBackground()
    }

    // MARK: - Контент страницы

    private func pageContent(_ item: OnboardingPage) -> some View {
        VStack(spacing: 20) {
            Image(systemName: item.systemImage)
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 136, height: 136)
                .background(Circle().fill(Theme.accentSoft))

            Text(item.title)
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text(item.subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        // Индикатор страниц рисует сам TabView поверх контента.
        .padding(.bottom, 40)
    }

    // MARK: - Кнопка

    private var continueButton: some View {
        Button(action: advance) {
            Text(page == Self.lastPage ? "Начать" : "Продолжить")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page == Self.lastPage ? "Начать пользоваться приложением" : "Следующая страница")
    }

    private func advance() {
        guard page < Self.lastPage else {
            onFinish()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            page += 1
        }
    }
}
