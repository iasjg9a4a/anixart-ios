import Foundation
import SwiftUI
import Combine

/// Куда ведёт ссылка или обычный переход внутри приложения.
enum AppRoute: Hashable {
    case release(id: Int)
    case profile(id: Int)
    case collection(id: Int)
    case search(query: String)
    case history
    case favorites
    case settings
}

/// Разбор deep links в `AppRoute`.
///
/// Поддерживаются:
/// - `anixart://release/123`, `anixart://profile/1`, `anixart://collection/55`
/// - `anixart://search?q=naruto`, `anixart://history`, `anixart://favorites`, `anixart://settings`
/// - `https://anixart-app.com/release/123`, `https://anixart.link/profile/1` — пути те же,
///   что у кастомной схемы.
///
/// Всё, что не разобралось (чужая схема, неизвестный путь, id не число, пустой `q`), — `nil`:
/// мусорная ссылка не должна ронять навигацию.
enum DeepLinkRouter {
    /// Схема своих ссылок.
    static let appScheme = "anixart"

    /// Домены universal link'ов: путь у них такой же, как у кастомной схемы.
    private static let webHosts: Set<String> = ["anixart-app.com", "anixart.link"]

    /// Query-параметр поиска: `?q=naruto`.
    private static let searchQueryName = "q"

    static func route(for url: URL) -> AppRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        let segments: [String]
        switch scheme {
        case appScheme:
            // anixart://release/123 — первая «папка» лежит в host, а не в path.
            segments = pathSegments(of: components, includingHost: true)
        case "http", "https":
            guard let host = components.host?.lowercased(),
                  webHosts.contains(bareHost(host)) else {
                return nil
            }
            segments = pathSegments(of: components, includingHost: false)
        default:
            return nil
        }

        return route(forSegments: segments, queryItems: components.queryItems ?? [])
    }

    /// Обёртка для universal link'ов из `NSUserActivity` (`onContinueUserActivity`).
    static func route(for userActivity: NSUserActivity) -> AppRoute? {
        guard let url = userActivity.webpageURL else { return nil }
        return route(for: url)
    }

    // MARK: - Разбор

    /// Host + pathComponents без пустых элементов: `anixart://release/123/` и
    /// `https://anixart.link/release/123` дают одинаковый набор сегментов.
    private static func pathSegments(of components: URLComponents,
                                     includingHost: Bool) -> [String] {
        var result: [String] = []
        if includingHost, let host = components.host, !host.isEmpty {
            result.append(host)
        }
        result.append(contentsOf: components.path.split(separator: "/").map(String.init))
        return result
    }

    /// `www.anixart-app.com` — тот же сайт, что и `anixart-app.com`.
    private static func bareHost(_ host: String) -> String {
        let prefix = "www."
        return host.hasPrefix(prefix) ? String(host.dropFirst(prefix.count)) : host
    }

    private static func route(forSegments segments: [String],
                              queryItems: [URLQueryItem]) -> AppRoute? {
        guard let head = segments.first else { return nil }
        let name = head.lowercased()

        switch name {
        case "release", "profile", "collection":
            // Ровно два сегмента: имя + положительный числовой id.
            guard segments.count == 2, let id = positiveID(segments[1]) else { return nil }
            switch name {
            case "release": return .release(id: id)
            case "profile": return .profile(id: id)
            default: return .collection(id: id)
            }
        case "search":
            guard segments.count == 1, let query = searchQuery(in: queryItems) else { return nil }
            return .search(query: query)
        case "history":
            guard segments.count == 1 else { return nil }
            return .history
        case "favorites":
            guard segments.count == 1 else { return nil }
            return .favorites
        case "settings":
            guard segments.count == 1 else { return nil }
            return .settings
        default:
            return nil
        }
    }

    private static func positiveID(_ raw: String) -> Int? {
        guard let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// Первый непустой `?q=`; значение `URLQueryItem` уже percent-decoded.
    private static func searchQuery(in items: [URLQueryItem]) -> String? {
        for item in items where item.name.lowercased() == searchQueryName {
            let value = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }
}

/// Стек навигации: сюда попадают и обычные переходы, и deep links.
///
/// Владелец — корневой экран, который держит `NavigationStack(path: $coordinator.path)`.
@MainActor
final class NavigationCoordinator: ObservableObject {
    /// Текущий стек маршрутов.
    @Published var path: [AppRoute] = []

    init(path: [AppRoute] = []) {
        self.path = path
    }

    /// Разбирает ссылку и кладёт маршрут в стек.
    /// - Returns: `false`, если ссылка чужая или битая — её надо просто проигнорировать.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let route = DeepLinkRouter.route(for: url) else { return false }
        push(route)
        return true
    }

    /// Открывает universal link, пришедший через `NSUserActivity`.
    @discardableResult
    func open(_ userActivity: NSUserActivity) -> Bool {
        guard let route = DeepLinkRouter.route(for: userActivity) else { return false }
        push(route)
        return true
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func popToRoot() {
        guard !path.isEmpty else { return }
        path.removeAll()
    }
}
