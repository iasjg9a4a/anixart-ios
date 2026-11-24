import Foundation
import SwiftUI

@main
struct AnixartApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session

    /// Навигация по ссылкам: `DeepLinkRouter` разбирает URL, координатор копит
    /// маршруты, а `RootView` показывает верхний из них модальным экраном.
    @StateObject private var coordinator = NavigationCoordinator()

    @State private var onboardingDone = UserDefaults.standard.bool(forKey: "anixart.onboarding.done")

    /// Отладочный запуск плеера из CI-скриншотов: `-anixart-open-player=1/8/1`.
    @State private var debugPlayer: DebugPlayerPresentation?

    var body: some View {
        Group {
            if onboardingDone {
                tabs
            } else {
                OnboardingView {
                    UserDefaults.standard.set(true, forKey: "anixart.onboarding.done")
                    onboardingDone = true
                }
            }
        }
        .task {
            await session.bootstrap()
            await MainActor.run { openLaunchRouteIfNeeded() }
            await openDebugPlayerIfNeeded()
            await openDebugVideoIfNeeded()
        }
        .onOpenURL { url in
            // Чужая или битая ссылка: `open` вернёт false, навигация не изменится.
            _ = coordinator.open(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            // `webpageURL` у universal link'а опционален — без него делать нечего.
            guard let url = activity.webpageURL else { return }
            _ = coordinator.open(url)
        }
        .sheet(isPresented: isDeepLinkPresented) {
            deepLinkScreen
        }
        .fullScreenCover(item: $debugPlayer) { presentation in
            PlayerView(
                target: presentation.target,
                releaseId: presentation.releaseId,
                sourceId: presentation.sourceId,
                position: presentation.position,
                onClose: { debugPlayer = nil }
            )
        }
    }

    /// Отладочный запуск сразу на нужном экране: `-anixart-open-route=release/1`.
    /// Используется CI-скриптом скриншотов (тап по симулятору недоступен).
    @MainActor
    private func openLaunchRouteIfNeeded() {
        let prefix = "-anixart-open-route="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return
        }
        let route = String(argument.dropFirst(prefix.count))
        guard let url = URL(string: "anixart://" + route) else { return }
        _ = coordinator.open(url)
    }

    /// Отладочный запуск плеера: `-anixart-open-player=<releaseId>/<sourceId>/<position>`.
    /// Нужен CI-скриншотам и проверке плееров без ручных тапов в симуляторе.
    ///
    /// Маршрут идёт тем же `EpisodePlaybackService.resolve(...)`, что и старт/смена
    /// серии в `PlayerView`: в CI-скриншоте `08-player.png` тогда будет то же видео,
    /// которое увидит пользователь (Kodik — нативный HLS через `ftor`, нативные
    /// источники — `AVPlayer`), а не web-прокси с «Error code: ds».
    @MainActor
    private func openDebugPlayerIfNeeded() async {
        let prefix = "-anixart-open-player="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return
        }
        let parts = String(argument.dropFirst(prefix.count)).split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return }
        let releaseId = parts[0]
        let sourceId = parts[1]
        let position = parts[2]
        do {
            let resolved = try await EpisodePlaybackService.resolve(
                releaseId: releaseId,
                sourceId: sourceId,
                position: position,
                title: nil
            )
            debugPlayer = DebugPlayerPresentation(
                target: resolved.target,
                releaseId: releaseId,
                sourceId: resolved.sourceId,
                position: position
            )
        } catch {
            // В скриншотах просто остаёмся на главной.
        }
    }

    /// Отладочный запуск видео с секции релиза: `-anixart-open-video=<releaseId>/<videoId>`.
    ///
    /// `videoId == 0` — первое видео релиза (например, трейлер). Видео ищется во всех
    /// блоках категорий; цель воспроизведения собирает `ReleaseVideo.playbackTarget`
    /// (YouTube — iframe-API, VK/RuTube — embed-страница). Контекста серии у видео нет,
    /// поэтому в `PlayerView` уходят только ссылка и заголовок.
    @MainActor
    private func openDebugVideoIfNeeded() async {
        let prefix = "-anixart-open-video="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return
        }
        let parts = String(argument.dropFirst(prefix.count)).split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let releaseId = parts[0]
        let videoId = parts[1]
        do {
            let blocks = try await APIClient.shared.releaseVideos(releaseId: releaseId)
            let videos = blocks.flatMap { $0.videos ?? [] }
            let video = videoId == 0
                ? videos.first
                : videos.first(where: { $0.id == videoId })
            guard let target = video?.playbackTarget else { return }
            debugPlayer = DebugPlayerPresentation(
                target: target,
                releaseId: nil,
                sourceId: nil,
                position: nil
            )
        } catch {
            // В скриншотах просто остаёмся на главной.
        }
    }

    // MARK: - Deep links

    /// Sheet существует ровно пока путь не пуст: закрытие (кнопкой или свайпом)
    /// очищает путь, новый маршрут снова его открывает. Пока идёт онбординг,
    /// ссылка ждёт в пути и открывается сразу после него, не перекрывая его.
    private var isDeepLinkPresented: Binding<Bool> {
        Binding(
            get: { onboardingDone && !coordinator.path.isEmpty },
            set: { presented in
                if !presented {
                    coordinator.popToRoot()
                }
            }
        )
    }

    @ViewBuilder
    private var deepLinkScreen: some View {
        if let route = coordinator.path.last {
            NavigationStack {
                destinationView(for: route)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Закрыть") {
                                coordinator.popToRoot()
                            }
                        }
                    }
            }
        }
    }

    private var tabs: some View {
        TabView {
            HomeView()
                .tabItem { Label("Главная", systemImage: "house.fill") }

            SearchView()
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }

            CollectionsView()
                .tabItem { Label("Коллекции", systemImage: "square.grid.2x2.fill") }

            ArticlesFeedView()
                .tabItem { Label("Статьи", systemImage: "doc.text.fill") }

            ProfileView()
                .tabItem { Label("Профиль", systemImage: "person.crop.circle.fill") }
        }
    }
}

/// Обёртка для `.fullScreenCover(item:)` в отладочном запуске плеера.
///
/// Контекст серии опционален: у видео с секции релиза его нет — плееру нужны
/// только `target` и заголовок внутри него.
private struct DebugPlayerPresentation: Identifiable {
    let id = UUID()
    let target: PlaybackTarget
    let releaseId: Int?
    let sourceId: Int?
    let position: Int?
}
