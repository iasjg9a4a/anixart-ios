import Foundation
import Combine

// MARK: - Ссылка на серию

/// Ссылка на серию, которую экран может спокойно хранить в состоянии.
///
/// `Episode` из ответа API несёт подписанную ссылку на видео: она привязана к IP
/// пользователя и живёт ограниченное время, поэтому держать её в UI нельзя.
/// В состоянии плеера остаются только идентификаторы и подпись, а свежую цель
/// по ним получает `EpisodePlaybackService.resolve(...)` — не этот сервис.
struct EpisodeRef: Equatable {
    /// Релиз, в котором находится серия.
    let releaseId: Int

    /// Озвучка. `nil` — если серия найдена вне каскада «озвучка → источник»
    /// (например, из истории просмотров, где сохранён только ключ прогресса).
    let typeId: Int?

    /// Источник: позиция серии уникальна только внутри источника.
    let sourceId: Int

    /// Номер серии внутри источника (нумерация Anixart начинается с 1).
    let position: Int

    /// Подпись для кнопки «Следующая серия» — `Episode.displayName`.
    let title: String
}

// MARK: - Сервис следующей серии

/// Поиск следующей серии — только discovery, без резолва ссылки.
///
/// Зачем отдельный сервис: `PlayerView` не должен знать, как устроен список серий
/// (`episode/{releaseId}/{typeId}/{sourceId}`) и когда его кэшировать. Плеер сообщает
/// только два факта — какая серия досмотрена и что пользователь нажал кнопку, —
/// а решения принимает этот класс. Поэтому SwiftUI здесь не импортируется:
/// сервис не зависит ни от одного экрана.
///
/// **Резолв ссылки — не здесь.** Цель воспроизведения для найденной серии отдаёт
/// `EpisodePlaybackService.resolve(...)`: он повторяет полный стартовый конвейер
/// (`episode/target` → `PlaybackResolver` → прямой HLS Kodik или нативный резолвер
/// Sibnet/AniLibria/RuTube/AnixPlayer). Упрощённый путь только через
/// `PlaybackResolver` оставлял Kodik на web-прокси («Error code: ds»), а нативные
/// источники — на `.web`-цели (бесконечная загрузка), поэтому `PlayerView` больше
/// не резолвит серию сам.
///
/// Кэш — в памяти процесса, ключ `releaseId-typeId-sourceId`, TTL 10 минут: пока
/// пользователь смотрит серии одного источника, список запрашивается один раз.
/// Подписанные ссылки (`episode/target`) здесь не запрашиваются и не кэшируются:
/// они живут ограниченное время и привязаны к IP, их берёт `EpisodePlaybackService`
/// в момент показа.
///
/// Экземпляр один на приложение — `NextEpisodeService.shared`. Класс `@MainActor`,
/// как остальные `ObservableObject` в проекте: подписка UI на `lastError` безопасна.
@MainActor
final class NextEpisodeService: ObservableObject {
    static let shared = NextEpisodeService()

    /// Текст последней ошибки `nextEpisode(...)`.
    ///
    /// Ошибку не пробрасываем наружу: плеер не должен ломаться из-за сети, а `nil`
    /// у `nextEpisode` значит просто «кнопку не показывать». При успешном поиске
    /// сбрасывается в `nil`.
    @Published private(set) var lastError: String?

    private let api: APIClient

    /// Записи кэша по ключу `releaseId-typeId-sourceId` (см. `cacheKey(...)`).
    private var cache: [String: CacheEntry] = [:]

    /// Сколько секунд список серий считается актуальным. За это время в онгоинге
    /// может выйти новая серия, но так как следующая ищется от текущей позиции,
    /// старый список даёт максимум «следующей нет» на последней серии.
    private let cacheLifetime: TimeInterval = 10 * 60

    /// Предел числа списков в кэше: длинные онгоинги дают большие списки, а смотреть
    /// одновременно пользователь может несколько релизов. Лишние вытесняются по дате.
    private let cacheLimit = 8

    private init(api: APIClient = .shared) {
        self.api = api
    }

    // MARK: - Следующая серия

    /// Найти серию, которая идёт сразу после `position` в том же источнике.
    ///
    /// Список серий берётся из кэша (TTL 10 минут) или запрашивается через
    /// `episode/{releaseId}/{typeId}/{sourceId}`. Возвращает `nil`, если следующей
    /// серии нет — досмотрена последняя — или список не удалось загрузить. В обоих
    /// случаях кнопку «Следующая серия» показывать не нужно, а причину ошибки можно
    /// прочитать в `lastError` (при «следующей нет» он `nil`).
    ///
    /// - Parameters:
    ///   - position: позиция текущей серии (та же, что в `PlaybackKey`).
    ///   - releaseId: релиз, в котором ищем следующую серию.
    ///   - typeId: озвучка, из `ReleaseViewModel.selectedTypeId`.
    ///   - sourceId: источник, внутри которого нумеруются позиции.
    func nextEpisode(after position: Int, releaseId: Int, typeId: Int, sourceId: Int) async -> EpisodeRef? {
        lastError = nil

        do {
            let episodes = try await loadEpisodes(releaseId: releaseId, typeId: typeId, sourceId: sourceId)
            guard let episode = episodes.first(where: { $0.position == position + 1 }) else {
                return nil
            }
            return EpisodeRef(
                releaseId: releaseId,
                typeId: typeId,
                sourceId: sourceId,
                position: episode.position,
                title: episode.displayName
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Кэш

    /// Забыть загруженные списки серий.
    ///
    /// Обычно он не нужен: записи сами истекают через 10 минут. Вызывать, если нужен
    /// гарантированно свежий список — например, после выхода из аккаунта или если
    /// пользователь жалуется, что новой серии «нет».
    func clearCache() {
        cache.removeAll()
    }

    /// Список серий из кэша или из сети.
    private func loadEpisodes(releaseId: Int, typeId: Int, sourceId: Int) async throws -> [Episode] {
        let key = cacheKey(releaseId: releaseId, typeId: typeId, sourceId: sourceId)
        let now = Date()

        if let entry = cache[key], entry.isFresh(at: now, lifetime: cacheLifetime) {
            return entry.episodes
        }

        let episodes = try await api.episodes(releaseId: releaseId, typeId: typeId, sourceId: sourceId)
        remember(episodes, forKey: key, at: now)
        return episodes
    }

    /// Ключ кэша: `releaseId-typeId-sourceId`.
    private func cacheKey(releaseId: Int, typeId: Int, sourceId: Int) -> String {
        "\(releaseId)-\(typeId)-\(sourceId)"
    }

    /// Складывает список в кэш, попутно выкидывая протухшие и самые старые записи.
    private func remember(_ episodes: [Episode], forKey key: String, at date: Date) {
        cache[key] = CacheEntry(episodes: episodes, loadedAt: date)

        let fresh = cache.filter { $0.value.isFresh(at: date, lifetime: cacheLifetime) }
        let newestFirst = fresh.sorted { $0.value.loadedAt > $1.value.loadedAt }
        cache = Dictionary(uniqueKeysWithValues: newestFirst.prefix(cacheLimit).map { ($0.key, $0.value) })
    }

    /// Список серий и время его загрузки.
    private struct CacheEntry {
        let episodes: [Episode]
        let loadedAt: Date

        /// Свежий ли список на момент `date`.
        func isFresh(at date: Date, lifetime: TimeInterval) -> Bool {
            date.timeIntervalSince(loadedAt) < lifetime
        }
    }
}
