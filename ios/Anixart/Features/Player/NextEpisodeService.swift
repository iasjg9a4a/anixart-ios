import Foundation
import Combine

// MARK: - Ссылка на серию

/// Ссылка на серию, которую экран может спокойно хранить в состоянии.
///
/// `Episode` из ответа API несёт подписанную ссылку на видео: она привязана к IP
/// пользователя и живёт ограниченное время, поэтому держать её в UI нельзя.
/// В состоянии плеера остаются только идентификаторы и подпись, а свежую ссылку
/// по ним получает `NextEpisodeService.resolvedTarget(for:)`.
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

/// Поиск следующей серии и получение ссылки на неё.
///
/// Зачем отдельный сервис: `PlayerView` не должен знать, как устроен список серий
/// (`episode/{releaseId}/{typeId}/{sourceId}`) и когда его кэшировать. Плеер сообщает
/// только два факта — какая серия досмотрена и что пользователь нажал кнопку, —
/// а решения принимает этот класс. Поэтому SwiftUI здесь не импортируется:
/// сервис не зависит ни от одного экрана.
///
/// Кэш — в памяти процесса, ключ `releaseId-typeId-sourceId`, TTL 10 минут: пока
/// пользователь смотрит серии одного источника, список запрашивается один раз.
/// Ссылки на видео (`episode/target`) не кэшируются никогда — они подписаны под IP
/// и истекают.
///
/// Порядок работы из `PlayerView` по `onFinished` (серия досмотрена):
///
/// 1. Экран должен помнить текущую цель в `@State private var target: PlaybackTarget`
///    (сейчас это `let target`), чтобы заменить её, не закрывая плеер. Идентификаторы
///    серии в `PlayerView` сейчас опциональны — перед вызовом сервиса их нужно
///    развернуть через `guard let`.
/// 2. В `NativePlayerView` передать замыкание `onFinished` (сейчас там `nil`):
///
///    ```swift
///    onFinished: {
///        Task {
///            let ref = await NextEpisodeService.shared.nextEpisode(
///                after: position,
///                releaseId: releaseId,
///                typeId: typeId,
///                sourceId: sourceId
///            )
///            guard let ref else { return }   // следующей нет или сеть недоступна
///            pendingNext = ref               // @State: показываем кнопку
///        }
///    }
///    ```
///
/// 3. Пока `pendingNext != nil` — показать кнопку «Следующая серия» с текстом
///    `ref.title`. Если `nextEpisode` вернул `nil`, кнопки нет: последняя серия
///    или ошибка сети (её текст — в `lastError`).
/// 4. Нажатие: получить свежую ссылку и заменить цель в плеере:
///
///    ```swift
///    Task {
///        do {
///            let episode = try await NextEpisodeService.shared.resolvedTarget(for: ref)
///            target = try PlaybackResolver.resolve(
///                episode: episode,
///                sourceName: sourceName,
///                title: "\(releaseTitle) — \(ref.title)"
///            )
///            pendingNext = nil
///        } catch {
///            errorMessage = error.localizedDescription
///        }
///    }
///    ```
///
/// 5. `resolvedTarget` вызывать в момент нажатия, а не заранее: ссылка живёт
///    ограниченное время и привязана к IP.
///
/// `onFinished` есть только у `NativePlayerView`; web-плеер (`PlayerWebView`) о конце
/// серии не сообщает, поэтому для Kodik/YouTube кнопку «Следующая серия» показать
/// не получится.
///
/// Ограничение интеграции: `typeId` сейчас не передаётся в `PlayerView` — при
/// подключении его нужно добавить в параметры экрана из `ReleaseViewModel.selectedTypeId`.
///
/// Экземпляр один на приложение — `NextEpisodeService.shared`. Класс `@MainActor`,
/// как остальные `ObservableObject` в проекте: подписка UI на `lastError` безопасна.
@MainActor
final class NextEpisodeService: ObservableObject {
    static let shared = NextEpisodeService()

    /// Текст последней ошибки `nextEpisode(...)`.
    ///
    /// Ошибку не пробрасываем наружу: плеер не должен ломаться из-за сети, а `nil`
    /// у `nextEpisode` значит просто «кнопку не показывать». `resolvedTarget(...)`
    /// наоборот бросает ошибку — он вызывается по явному нажатию, и экран сам решает,
    /// что показать. При успешном поиске сбрасывается в `nil`.
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

    /// Получить серию вместе со свежей подписанной ссылкой (`episode/target/...`).
    ///
    /// Не кэшируйте результат: `url` привязан к IP и живёт ограниченное время,
    /// поэтому запрашивайте ссылку непосредственно перед показом серии. Ошибки
    /// `APIClient` (`APIError`) пробрасываются наружу — экран покажет их сам.
    ///
    /// - Parameter ref: серия, найденная `nextEpisode(...)` (или собранная вручную).
    func resolvedTarget(for ref: EpisodeRef) async throws -> Episode {
        try await api.episodeTarget(
            releaseId: ref.releaseId,
            sourceId: ref.sourceId,
            position: ref.position
        )
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
