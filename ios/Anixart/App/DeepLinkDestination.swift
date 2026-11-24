import SwiftUI

/// Перевод маршрута `AppRoute` в конкретный экран приложения.
///
/// Одна точка соответствия «маршрут → экран»: `DeepLinkRouter` и
/// `NavigationCoordinator` ничего не знают про экраны, а `RootView` показывает
/// результат в модальном навигационном стеке с кнопкой закрытия.
///
/// Права доступа здесь сознательно не проверяются: `history`, `favorites` и
/// `settings` открываются и для гостя — эти экраны сами показывают состояние
/// «нужно войти». Так deep link на избранное не превращается в молчание или
/// в чужой экран.
///
/// - Note: у экранов уже есть собственный `NavigationStack` и `navigationTitle`;
///   `RootView` дополнительно оборачивает их в стек, чтобы `release` (у него
///   своего стека нет) тоже получил навигационное окружение и кнопку закрытия.
///
/// `@MainActor` — как у `View.body` в свежих SDK: экраны создаются на главном
/// акторе, поэтому функция тоже изолирована на нём.
@MainActor
@ViewBuilder
func destinationView(for route: AppRoute) -> some View {
    switch route {
    case .release(let id):
        ReleaseView(releaseId: id)

    case .profile(let id):
        UserProfileView(userId: id)

    case .collection(let id):
        CollectionDetailView(collectionId: id)

    case .search(let query):
        // Стартовый запрос из `anixart://search?q=...` — SearchView принимает его в init.
        SearchView(initialQuery: query)

    case .history:
        HistoryView()

    case .favorites:
        FavoritesView()

    case .settings:
        SettingsView()
    }
}
